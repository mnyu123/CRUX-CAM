package com.cruxcam.crux_cam

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.MediaMetadataRetriever
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.exifinterface.media.ExifInterface
import com.google.android.gms.tasks.Tasks
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.core.Delegate
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.poselandmarker.PoseLandmarker
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.pose.PoseDetection
import com.google.mlkit.vision.pose.PoseDetector
import com.google.mlkit.vision.pose.accurate.AccuratePoseDetectorOptions
import io.flutter.FlutterInjector
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max
import kotlin.math.roundToInt

/** 프레임 추출과 모델 실행을 같은 작업 큐에서 처리하여 화면 스레드를 막지 않습니다. */
class PoseBridge(private val context: Context, messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "crux_cam/pose")
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val sessions = ConcurrentHashMap<String, Session>()
    private var disposed = false

    init { channel.setMethodCallHandler(this) }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (disposed) { result.error("closed", "분석 연결이 종료되었습니다.", null); return }
        when (call.method) {
            "engines" -> result.success(listOf("mediapipe_full", "mediapipe_lite", "mlkit_accurate"))
            "open" -> {
                val id = call.argument<String>("id")
                val path = call.argument<String>("path")
                val type = call.argument<String>("type")
                val engine = call.argument<String>("engine")
                if (id.isNullOrEmpty() || path.isNullOrEmpty() || type !in listOf("image", "video") ||
                    engine !in listOf("mediapipe_full", "mediapipe_lite", "mlkit_accurate")) {
                    result.error("arguments", "분석 요청 형식이 올바르지 않습니다.", null); return
                }
                if (sessions.isNotEmpty()) {
                    result.error("busy", "이전 분석의 정리가 끝난 뒤 다시 시도해주세요.", null); return
                }
                // 준비 중에도 취소할 수 있도록 모델을 열기 전에 세션을 먼저 등록합니다.
                val session = Session(id, path, type == "video", engine!!)
                sessions[id] = session
                run(result) {
                    session.checkActive()
                    session.prepare()
                    session.checkActive()
                    mapOf("width" to session.width, "height" to session.height,
                        "durationMs" to session.durationMs,
                        "storageDirectory" to File(context.filesDir, "analysis").absolutePath)
                }
            }
            "frame" -> {
                val id = call.argument<String>("id")
                val session = if (id == null) null else sessions[id]
                val time = call.argument<Number>("timeMs")?.toLong()
                if (session == null || time == null) {
                    result.error("session", "분석 세션을 찾을 수 없습니다.", null); return
                }
                run(result) { session.analyze(time, call.argument<Boolean>("preview") == true) }
            }
            "close" -> {
                val id = call.argument<String>("id")
                val session = if (id == null) null else sessions[id]
                if (session == null) { result.success(null); return }
                // 대기 중인 프레임도 즉시 취소 상태를 보게 하되 모델 해제는 같은 큐에서 합니다.
                session.cancelled.set(true)
                run(result) {
                    session.close()
                    sessions.remove(session.id, session)
                    null
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun run(result: MethodChannel.Result, action: () -> Any?) {
        worker.execute {
            try {
                val value = action()
                main.post { result.success(value) }
            } catch (error: Exception) {
                val message = when (error) {
                    is Cancelled -> "분석을 취소했습니다."
                    is IllegalArgumentException -> error.message ?: "분석 입력을 확인해주세요."
                    else -> "영상 또는 모델을 처리하지 못했습니다. 다른 파일이나 모델로 시도해주세요."
                }
                android.util.Log.e("CruxPose", "관절 분석 처리 실패", error)
                main.post { result.error(if (error is Cancelled) "cancelled" else "analysis", message, null) }
            }
        }
    }

    fun dispose() {
        if (disposed) return
        disposed = true
        channel.setMethodCallHandler(null)
        sessions.values.forEach { it.cancelled.set(true) }
        worker.execute {
            sessions.values.forEach { it.close() }
            sessions.clear()
        }
        worker.shutdown()
    }

    private class Cancelled : RuntimeException()

    private inner class Session(val id: String, private val path: String,
        private val video: Boolean, private val engine: String) {
        val cancelled = AtomicBoolean(false)
        var width = 0
        var height = 0
        var durationMs = 0L
        private var retriever: MediaMetadataRetriever? = null
        private var photo: Bitmap? = null
        private var firstFrame: Bitmap? = null
        private var landmarker: PoseLandmarker? = null
        private var mlKit: PoseDetector? = null
        private var lastTime = -1L

        fun checkActive() { if (cancelled.get()) throw Cancelled() }

        fun prepare() {
            require(File(path).isFile) { "선택한 파일에 접근할 수 없습니다. 다시 선택해주세요." }
            if (video) {
                val decoder = MediaMetadataRetriever()
                retriever = decoder
                decoder.setDataSource(path)
                durationMs = decoder.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0
                require(durationMs in 1..600000) { "현재는 10분 이하 영상 분석을 지원합니다." }
                val rawWidth = decoder.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
                val rawHeight = decoder.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
                require(rawWidth > 0 && rawHeight > 0) { "영상 해상도를 읽을 수 없습니다." }
                val rotation = decoder.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
                width = if (rotation % 180 == 0) rawWidth else rawHeight
                height = if (rotation % 180 == 0) rawHeight else rawWidth
                firstFrame = readVideo(0)
                // Android 디코더가 회전을 적용한 실제 프레임 비율을 결과 좌표의 기준으로 씁니다.
                width = firstFrame!!.width
                height = firstFrame!!.height
            } else {
                photo = readPhoto(path)
                width = photo!!.width
                height = photo!!.height
            }
            checkActive()
            if (engine == "mlkit_accurate") {
                val options = AccuratePoseDetectorOptions.Builder()
                    .setDetectorMode(if (video) AccuratePoseDetectorOptions.STREAM_MODE else AccuratePoseDetectorOptions.SINGLE_IMAGE_MODE)
                    .build()
                mlKit = PoseDetection.getClient(options)
            } else {
                val model = if (engine == "mediapipe_lite") "pose_landmarker_lite.task" else "pose_landmarker_full.task"
                val asset = FlutterInjector.instance().flutterLoader().getLookupKeyForAsset("assets/models/$model")
                val options = PoseLandmarker.PoseLandmarkerOptions.builder()
                    .setBaseOptions(BaseOptions.builder().setModelAssetPath(asset).setDelegate(Delegate.CPU).build())
                    .setRunningMode(if (video) RunningMode.VIDEO else RunningMode.IMAGE)
                    .setNumPoses(4).setMinPoseDetectionConfidence(0.5f)
                    .setMinPosePresenceConfidence(0.5f).setMinTrackingConfidence(0.5f)
                    .setOutputSegmentationMasks(false).build()
                landmarker = PoseLandmarker.createFromOptions(context, options)
            }
        }

        fun analyze(timeMs: Long, preview: Boolean): Map<String, Any> {
            checkActive()
            require(timeMs >= 0 && (!video || timeMs < durationMs) && timeMs > lastTime) {
                "분석 프레임은 영상 범위 안에서 시간순으로 요청해주세요."
            }
            val frame = if (video) {
                if (timeMs == 0L && firstFrame != null) firstFrame!!.also { firstFrame = null }
                else readVideo(timeMs)
            } else photo ?: throw IllegalArgumentException("사진을 읽을 수 없습니다.")
            try {
                checkActive()
                // SDK가 입력 이미지의 수명을 관리할 수 있으므로 미리보기는 먼저 만듭니다.
                val previewBytes = if (preview) ByteArrayOutputStream().use { bytes ->
                    frame.compress(Bitmap.CompressFormat.JPEG, 85, bytes)
                    bytes.toByteArray()
                } else null
                val start = SystemClock.elapsedRealtimeNanos()
                val poses: List<List<List<Float>>> = if (engine == "mlkit_accurate") {
                    val detection = Tasks.await(mlKit!!.process(InputImage.fromBitmap(frame, 0)), 30, TimeUnit.SECONDS)
                    if (detection.allPoseLandmarks.isEmpty()) emptyList() else listOf((0..32).map { i ->
                        val p = detection.getPoseLandmark(i)
                        if (p == null) listOf(0f, 0f, 0f, 0f) else listOf(
                            p.position.x / frame.width, p.position.y / frame.height,
                            p.position3D.z / frame.width, p.inFrameLikelihood)
                    })
                } else {
                    val image = BitmapImageBuilder(frame).build()
                    try {
                        val detection = if (video) landmarker!!.detectForVideo(image, timeMs) else landmarker!!.detect(image)
                        detection.landmarks().map { points -> points.map { p ->
                            listOf(p.x(), p.y(), p.z(), minOf(p.visibility().orElse(0f), p.presence().orElse(1f)))
                        } }
                    } finally { image.close() }
                }
                val inferenceMs = (SystemClock.elapsedRealtimeNanos() - start) / 1000000.0
                checkActive()
                lastTime = timeMs
                val output = mutableMapOf<String, Any>("timeMs" to timeMs, "poses" to poses, "inferenceMs" to inferenceMs)
                if (previewBytes != null) output["preview"] = previewBytes
                return output
            } finally {
                if (video && !frame.isRecycled) frame.recycle()
            }
        }

        private fun readVideo(timeMs: Long): Bitmap {
            val scale = minOf(1.0, 960.0 / max(width, height))
            val decoder = retriever ?: throw IllegalArgumentException("영상이 준비되지 않았습니다.")
            val bitmap = if (Build.VERSION.SDK_INT >= 27) {
                decoder.getScaledFrameAtTime(timeMs * 1000, MediaMetadataRetriever.OPTION_CLOSEST,
                    max(1, (width * scale).roundToInt()), max(1, (height * scale).roundToInt()))
            } else decoder.getFrameAtTime(timeMs * 1000, MediaMetadataRetriever.OPTION_CLOSEST)
            requireNotNull(bitmap) { "이 시점의 영상 프레임을 읽을 수 없습니다." }
            return shrink(bitmap)
        }

        fun close() {
            // 같은 세션에 취소와 종료가 동시에 와도 두 번 해제하지 않게 참조를 비웁니다.
            val model = landmarker; landmarker = null
            val detector = mlKit; mlKit = null
            val decoder = retriever; retriever = null
            val image = photo; photo = null
            val first = firstFrame; firstFrame = null
            runCatching { model?.close() }
            runCatching { detector?.close() }
            runCatching { decoder?.release() }
            if (image != null && !image.isRecycled) image.recycle()
            if (first != null && !first.isRecycled) first.recycle()
        }
    }

    private fun readPhoto(path: String): Bitmap {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        require(bounds.outWidth > 0 && bounds.outHeight > 0) { "사진을 읽을 수 없습니다." }
        var sample = 1
        while (max(bounds.outWidth, bounds.outHeight) / sample > 1920) sample *= 2
        val bitmap = BitmapFactory.decodeFile(path, BitmapFactory.Options().apply {
            inSampleSize = sample; inPreferredConfig = Bitmap.Config.ARGB_8888
        }) ?: throw IllegalArgumentException("사진 형식을 지원하지 않습니다.")
        val exif = ExifInterface(path)
        val matrix = Matrix()
        matrix.postRotate(exif.rotationDegrees.toFloat())
        if (exif.isFlipped) matrix.postScale(-1f, 1f)
        val oriented = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
        if (oriented !== bitmap) bitmap.recycle()
        return shrink(oriented)
    }

    private fun shrink(bitmap: Bitmap): Bitmap {
        val scale = minOf(1.0, 960.0 / max(bitmap.width, bitmap.height))
        var current = bitmap
        if (scale < 1) {
            current = Bitmap.createScaledBitmap(bitmap, max(1, (bitmap.width * scale).roundToInt()),
                max(1, (bitmap.height * scale).roundToInt()), true)
            if (current !== bitmap) bitmap.recycle()
        }
        if (current.config != Bitmap.Config.ARGB_8888) {
            val copy = current.copy(Bitmap.Config.ARGB_8888, false)
            current.recycle()
            current = copy
        }
        return current
    }
}
