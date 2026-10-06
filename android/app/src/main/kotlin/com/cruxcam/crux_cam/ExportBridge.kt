package com.cruxcam.crux_cam

import android.app.Activity
import android.content.ContentValues
import android.content.Intent
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.provider.MediaStore
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.Size
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.GlMatrixTransformation
import androidx.media3.transformer.*
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.*

@UnstableApi
class ExportBridge(private val activity: Activity, messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "crux_cam/export")
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val directory = File(activity.filesDir, "exports").apply { mkdirs() }
    private val jobs = mutableMapOf<String, Job>()
    private var pendingSave: Pair<File, MethodChannel.Result>? = null
    private var disposed = false

    private class Job(val id: String, val partial: File, val output: File) {
        val cancelled = AtomicBoolean(false)
        var transformer: Transformer? = null
        var state = "rendering"
        var error: String? = null
        var metadata: Map<String, Any>? = null
    }
    private data class Frame(val time: Long, val rect: DoubleArray, val following: Boolean)

    init {
        // 비정상 종료 때 남은 우리 작업 파일만 제거하고 완료된 영상은 보관합니다.
        directory.listFiles()?.filter { it.name.endsWith(".partial") }?.forEach { it.delete() }
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "start" -> start(call, result)
                "status" -> {
                    val job = jobs[call.argument<String>("id")] ?: error("작업을 찾지 못했습니다.")
                    val progress = ProgressHolder()
                    val available = job.transformer?.getProgress(progress) == Transformer.PROGRESS_STATE_AVAILABLE
                    result.success(mutableMapOf<String, Any?>("state" to job.state,
                        "progress" to if (available) progress.progress / 100.0 else null,
                        "error" to job.error).apply { job.metadata?.let { putAll(it) } })
                }
                "cancel", "release" -> {
                    val id = call.argument<String>("id")
                    jobs[id]?.let { job ->
                        if (job.state == "rendering") cancel(job)
                        if (call.method == "release") jobs.remove(id)
                    }
                    result.success(null)
                }
                "save" -> save(call, result)
                else -> result.notImplemented()
            }
        } catch (e: Exception) { result.error("export_error", e.message ?: "영상 처리에 실패했습니다.", null) }
    }

    private fun start(call: MethodCall, result: MethodChannel.Result) {
        check(jobs.values.none { it.state == "rendering" }) { "이미 영상을 내보내고 있습니다." }
        val id = call.argument<String>("id") ?: error("작업 번호가 없습니다.")
        check(id.matches(Regex("[0-9]+")) && !jobs.containsKey(id)) { "작업 번호가 올바르지 않습니다." }
        val path = call.argument<String>("path") ?: error("원본 영상이 없습니다.")
        val timeline = call.argument<Map<String, Any>>("timeline") ?: error("크롭 경로가 없습니다.")
        val settings = call.argument<Map<String, Any>>("settings") ?: error("출력 설정이 없습니다.")
        val job = Job(id, File(directory, "CRUX_$id.mp4.partial"), File(directory, "CRUX_$id.mp4"))
        jobs[id] = job
        worker.execute {
            try {
                val frames = parseFrames(timeline)
                val aspect = (timeline["outputAspect"] as Number).toDouble()
                require(aspect.isFinite() && aspect in .1..10.0) { "출력 비율이 올바르지 않습니다." }
                require(settings["container"] == "mp4" && settings["codec"] == "h264") { "지원하지 않는 출력 형식입니다." }
                val retriever = MediaMetadataRetriever()
                val source = try {
                    retriever.setDataSource(activity, Uri.fromFile(File(path)))
                    val w = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)!!.toInt()
                    val h = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)!!.toInt()
                    val rotation = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toInt() ?: 0
                    val duration = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)!!.toLong()
                    require(duration in 1..600_000) { "10분 이하의 영상을 선택해주세요." }
                    Triple(if (rotation % 180 == 0) w else h, if (rotation % 180 == 0) h else w, duration)
                } finally { retriever.release() }
                val requested = (settings["shortSide"] as Number).toInt()
                require(requested == 720 || requested == 1080) { "출력 해상도가 올바르지 않습니다." }
                val shortSide = min(requested, min(source.first, source.second)).toDouble()
                val width = ((if (aspect < 1) shortSide else shortSide * aspect) / 2).roundToInt() * 2
                val height = ((if (aspect < 1) shortSide / aspect else shortSide) / 2).roundToInt() * 2
                require(width in 16..4096 && height in 16..4096) { "지원하지 않는 출력 크기입니다." }
                val bitrate = (settings["bitrate"] as Number).toInt()
                require(bitrate in 1_000_000..20_000_000) { "화질 설정이 올바르지 않습니다." }
                // 앱 파일과 갤러리 복사본에 쓸 여유를 함께 확인합니다. 실제 용량은 인코더에 따라 달라집니다.
                val estimated = bitrate.toLong() * source.third / 8000 + 10_000_000
                require(StatFs(directory.path).availableBytes > estimated * 2 + 50_000_000) { "저장 공간이 부족합니다. 공간을 확보하거나 기본 화질을 선택해주세요." }
                main.post {
                    if (disposed || job.cancelled.get() || jobs[id] !== job) {
                        result.error("cancelled", "내보내기를 취소했습니다.", null)
                    } else try {
                        val effects = Effects(emptyList(), listOf(TimelineCrop(frames, width, height)))
                        val edited = EditedMediaItem.Builder(MediaItem.fromUri(Uri.fromFile(File(path))))
                            .setEffects(effects).setRemoveAudio(settings["keepAudio"] != true).build()
                        val encoder = DefaultEncoderFactory.Builder(activity)
                            .setEnableFallback(false)
                            .setRequestedVideoEncoderSettings(VideoEncoderSettings.Builder().setBitrate(bitrate).build()).build()
                        val transformer = Transformer.Builder(activity)
                            .setVideoMimeType(MimeTypes.VIDEO_H264).setAudioMimeType(MimeTypes.AUDIO_AAC)
                            .setEncoderFactory(encoder)
                            // 회전은 SDK가 처리하며 완료 확인 때도 표시 방향 기준 해상도를 읽습니다.
                            .addListener(object : Transformer.Listener {
                                override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                                    if (job.cancelled.get()) { job.partial.delete(); return }
                                    worker.execute {
                                        try {
                                            val metadata = inspect(job.partial)
                                            synchronized(job) {
                                                if (job.cancelled.get()) return@execute
                                                check(job.partial.renameTo(job.output)) { "완료된 파일을 저장하지 못했습니다." }
                                            }
                                            main.post {
                                                if (job.cancelled.get()) return@post
                                                job.metadata = metadata + ("path" to job.output.path)
                                                job.state = "completed"; job.transformer = null
                                            }
                                        } catch (e: Exception) { main.post { fail(job, e.message ?: "출력 확인에 실패했습니다.") } }
                                    }
                                }
                                override fun onError(composition: Composition, exportResult: ExportResult, exportException: ExportException) {
                                    fail(job, "기기에서 이 영상의 변환을 완료하지 못했습니다 (${exportException.errorCodeName}). 기본 화질로 다시 시도해주세요.")
                                }
                            }).build()
                        job.transformer = transformer
                        val composition = Composition.Builder(EditedMediaItemSequence.Builder(edited).build())
                            .setHdrMode(Composition.HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_OPEN_GL).build()
                        transformer.start(composition, job.partial.path)
                        result.success(null)
                    } catch (e: Exception) { fail(job, e.message ?: "내보내기를 시작하지 못했습니다."); result.error("export_failed", job.error, null) }
                }
            } catch (e: Exception) {
                main.post { fail(job, e.message ?: "원본 영상을 읽지 못했습니다."); result.error("export_failed", job.error, null) }
            }
        }
    }

    private fun parseFrames(timeline: Map<String, Any>): List<Frame> {
        require(timeline["coordinateSpace"] == "upright_normalized") { "크롭 좌표가 올바르지 않습니다." }
        val input = timeline["frames"] as? List<*> ?: error("크롭 경로가 없습니다.")
        require(input.size in 1..6000)
        var previous = -1L
        return input.map {
            val map = it as Map<*, *>
            val time = (map["timeMs"] as Number).toLong()
            val rect = (map["rect"] as List<*>).map { n -> (n as Number).toDouble() }.toDoubleArray()
            require(time > previous && time in 0..600_000 && rect.size == 4 && rect.all { n -> n.isFinite() } &&
                rect[0] >= 0 && rect[1] >= 0 && rect[2] > 0 && rect[3] > 0 &&
                rect[0] + rect[2] <= 1.000001 && rect[1] + rect[3] <= 1.000001) { "크롭 경로가 올바르지 않습니다." }
            previous = time
            Frame(time, rect, map["status"] == "following")
        }
    }

    private class TimelineCrop(val frames: List<Frame>, val width: Int, val height: Int) : GlMatrixTransformation {
        override fun configure(inputWidth: Int, inputHeight: Int) = Size(width, height)
        override fun getGlMatrixArray(presentationTimeUs: Long): FloatArray {
            val time = presentationTimeUs / 1000
            var low = 0; var high = frames.lastIndex
            while (low < high) { val mid = (low + high + 1) / 2; if (frames[mid].time <= time) low = mid else high = mid - 1 }
            val a = frames[low]; val b = frames.getOrNull(low + 1)
            val fraction = if (b != null && a.following && b.following)
                ((time - a.time).toDouble() / (b.time - a.time)).coerceIn(0.0, 1.0) else 0.0
            val r = DoubleArray(4) { a.rect[it] + ((b?.rect?.get(it) ?: a.rect[it]) - a.rect[it]) * fraction }
            // 화면 좌표는 아래로 증가하고 OpenGL 좌표는 위로 증가하므로 세로 이동의 부호를 바꿉니다.
            val matrix = FloatArray(16)
            matrix[0] = (1 / r[2]).toFloat(); matrix[5] = (1 / r[3]).toFloat()
            matrix[10] = 1f; matrix[15] = 1f
            matrix[12] = ((1 - 2 * r[0] - r[2]) / r[2]).toFloat()
            matrix[13] = ((2 * r[1] + r[3] - 1) / r[3]).toFloat()
            return matrix
        }
    }

    private fun inspect(file: File): Map<String, Any> {
        val extractor = MediaExtractor()
        var audio = false; var video: MediaFormat? = null
        try {
            extractor.setDataSource(file.path)
            for (i in 0 until extractor.trackCount) {
                val f = extractor.getTrackFormat(i)
                val mime = f.getString(MediaFormat.KEY_MIME) ?: ""
                if (mime.startsWith("audio/")) audio = true
                if (mime.startsWith("video/")) { check(mime == "video/avc") { "H.264 출력 확인에 실패했습니다." }; video = f }
            }
            val format = video ?: error("출력 영상이 비어 있습니다.")
            val rotation = if (format.containsKey(MediaFormat.KEY_ROTATION)) format.getInteger(MediaFormat.KEY_ROTATION) else 0
            val w = format.getInteger(MediaFormat.KEY_WIDTH); val h = format.getInteger(MediaFormat.KEY_HEIGHT)
            return mapOf("width" to if (rotation % 180 == 0) w else h,
                "height" to if (rotation % 180 == 0) h else w, "sizeBytes" to file.length(),
                "durationMs" to format.getLong(MediaFormat.KEY_DURATION) / 1000, "hasAudio" to audio)
        } finally { extractor.release() }
    }

    private fun fail(job: Job, message: String) {
        if (job.cancelled.get()) return
        job.state = "failed"; job.error = message; job.transformer = null; job.partial.delete()
    }
    private fun cancel(job: Job) {
        synchronized(job) {
            job.cancelled.set(true)
            // 완료 확인과 취소가 겹치면 이 작업이 만든 두 파일만 제거합니다.
            job.partial.delete(); job.output.delete()
        }
        job.transformer?.cancel(); job.transformer = null
        job.partial.delete(); job.state = "cancelled"
    }

    private fun save(call: MethodCall, result: MethodChannel.Result) {
        val file = File(call.argument<String>("path") ?: "").canonicalFile
        require(file.parentFile == directory.canonicalFile && file.extension == "mp4" && file.isFile) { "앱에서 완료한 영상만 저장할 수 있습니다." }
        check(pendingSave == null) { "이미 저장하고 있습니다." }
        if (Build.VERSION.SDK_INT >= 29) {
            worker.execute {
                var uri: Uri? = null
                try {
                    val values = ContentValues().apply {
                        put(MediaStore.Video.Media.DISPLAY_NAME, file.name); put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
                        put(MediaStore.Video.Media.RELATIVE_PATH, Environment.DIRECTORY_MOVIES + "/CRUX-CAM")
                        put(MediaStore.Video.Media.IS_PENDING, 1)
                    }
                    uri = activity.contentResolver.insert(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, values) ?: error("갤러리에 파일을 만들지 못했습니다.")
                    activity.contentResolver.openOutputStream(uri, "w")!!.use { out -> file.inputStream().use { it.copyTo(out) } }
                    activity.contentResolver.update(uri, ContentValues().apply { put(MediaStore.Video.Media.IS_PENDING, 0) }, null, null)
                    main.post { result.success(uri.toString()) }
                } catch (e: Exception) {
                    uri?.let { activity.contentResolver.delete(it, null, null) }
                    main.post { result.error("save_failed", "갤러리 저장에 실패했습니다. 앱에 보관된 영상은 다시 저장할 수 있습니다.", null) }
                }
            }
        } else {
            // 구형 Android에서는 넓은 저장소 권한 대신 사용자가 고른 파일 위치에만 저장합니다.
            pendingSave = file to result
            try { activity.startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE); type = "video/mp4"; putExtra(Intent.EXTRA_TITLE, file.name)
            }, 7303) } catch (e: Exception) { pendingSave = null; throw e }
        }
    }

    fun onActivityResult(request: Int, code: Int, data: Intent?): Boolean {
        if (request != 7303) return false
        val pending = pendingSave ?: return true
        pendingSave = null
        val uri = data?.data
        if (code != Activity.RESULT_OK || uri == null) { pending.second.success(null); return true }
        worker.execute {
            try {
                activity.contentResolver.openOutputStream(uri, "w")!!.use { out -> pending.first.inputStream().use { it.copyTo(out) } }
                main.post { pending.second.success(uri.toString()) }
            } catch (e: Exception) { main.post { pending.second.error("save_failed", "선택한 위치에 저장하지 못했습니다. 다시 시도해주세요.", null) } }
        }
        return true
    }

    fun dispose() {
        disposed = true; channel.setMethodCallHandler(null)
        jobs.values.filter { it.state == "rendering" }.forEach { cancel(it) }; jobs.clear()
        pendingSave?.second?.error("cancelled", "저장을 취소했습니다.", null); pendingSave = null
        // 준비·복사 중인 작업은 종료까지 마치고 새 작업만 차단합니다.
        worker.shutdown()
    }
}
