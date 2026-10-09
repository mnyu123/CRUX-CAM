package com.cruxcam.crux_cam

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.Matrix
import android.media.MediaMetadataRetriever
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.exifinterface.media.ExifInterface
import com.google.android.gms.tasks.Tasks
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.framework.image.MPImage
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.core.Delegate
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.poselandmarker.PoseLandmarker
import com.google.mediapipe.tasks.vision.poselandmarker.PoseLandmarkerResult
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
                val rawRegion = call.argument<List<Number>>("region")
                val region = rawRegion?.map { it.toDouble() }
                if (region != null && (region.size != 4 || region.any { !it.isFinite() || it !in 0.0..1.0 } ||
                    region[2] - region[0] < 0.05 || region[3] - region[1] < 0.05)) {
                    result.error("arguments", "분석 영역이 올바르지 않습니다.", null); return
                }
                val session = Session(id, path, type == "video", engine!!, region)
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
            "refine" -> {
                val id = call.argument<String>("id")
                val session = if (id == null) null else sessions[id]
                val time = call.argument<Number>("timeMs")?.toLong()
                val region = call.argument<List<Number>>("region")?.map { it.toDouble() }
                if (session == null || time == null) {
                    result.error("session", "분석 세션을 찾을 수 없습니다.", null); return
                }
                if (region == null || region.size != 4 || region.any { !it.isFinite() || it !in 0.0..1.0 } ||
                    region[2] - region[0] < 0.05 || region[3] - region[1] < 0.05) {
                    result.error("arguments", "다시 찾을 영역이 올바르지 않습니다.", null); return
                }
                run(result) { session.refine(time, region) }
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
        private val video: Boolean, private val engine: String, private val region: List<Double>?) {
        val cancelled = AtomicBoolean(false)
        var width = 0
        var height = 0
        var durationMs = 0L
        private var retriever: MediaMetadataRetriever? = null
        private var photo: Bitmap? = null
        private var firstFrame: Bitmap? = null
        private var landmarker: PoseLandmarker? = null
        private var mlKit: PoseDetector? = null
        // MediaPipe가 등진 자세나 빠른 움직임에서 놓친 사람을 보충하는 보조 모델입니다.
        private var assist: PoseDetector? = null
        // 놓친 구간을 다시 찾을 때만 만드는 모델입니다. 시간 순서와 관계없이 한 장씩 분석합니다.
        private var refineLandmarker: PoseLandmarker? = null
        private var refineMlKit: PoseDetector? = null
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
                    .setDetectorMode(if (video && region == null) AccuratePoseDetectorOptions.STREAM_MODE else AccuratePoseDetectorOptions.SINGLE_IMAGE_MODE)
                    .build()
                mlKit = PoseDetection.getClient(options)
            } else {
                landmarker = createLandmarker(if (video && region == null) RunningMode.VIDEO else RunningMode.IMAGE)
                // ML Kit는 한 사람만 찾지만 얼굴이 보이지 않는 등진 자세에서 더 잘 찾는 경우가 많습니다.
                // 같은 프레임에 한 번 더 실행하는 비용은 영상 디코딩보다 작아 모든 프레임에 함께 실행합니다.
                assist = PoseDetection.getClient(AccuratePoseDetectorOptions.Builder()
                    .setDetectorMode(if (video && region == null) AccuratePoseDetectorOptions.STREAM_MODE else AccuratePoseDetectorOptions.SINGLE_IMAGE_MODE)
                    .build())
            }
        }

        private fun createLandmarker(mode: RunningMode, confidence: Float = 0.5f): PoseLandmarker {
            val model = if (engine == "mediapipe_lite") "pose_landmarker_lite.task" else "pose_landmarker_full.task"
            val asset = FlutterInjector.instance().flutterLoader().getLookupKeyForAsset("assets/models/$model")
            val options = PoseLandmarker.PoseLandmarkerOptions.builder()
                .setBaseOptions(BaseOptions.builder().setModelAssetPath(asset).setDelegate(Delegate.CPU).build())
                .setRunningMode(mode)
                .setNumPoses(4).setMinPoseDetectionConfidence(confidence)
                .setMinPosePresenceConfidence(confidence).setMinTrackingConfidence(0.5f)
                .setOutputSegmentationMasks(false).build()
            return PoseLandmarker.createFromOptions(context, options)
        }

        /** 잘라낸 입력에서 찾은 좌표를 원본 전체 화면 기준 0~1 좌표로 되돌립니다. */
        private fun mlKitPoses(detector: PoseDetector, input: Bitmap, left: Int, top: Int, frame: Bitmap): List<List<List<Float>>> {
            val detection = Tasks.await(detector.process(InputImage.fromBitmap(input, 0)), 30, TimeUnit.SECONDS)
            return if (detection.allPoseLandmarks.isEmpty()) emptyList() else listOf((0..32).map { i ->
                val p = detection.getPoseLandmark(i)
                if (p == null) listOf(0f, 0f, 0f, 0f) else listOf(
                    (left + p.position.x) / frame.width, (top + p.position.y) / frame.height,
                    p.position3D.z / frame.width, p.inFrameLikelihood)
            })
        }

        private fun mediaPipePoses(detection: PoseLandmarkerResult, input: Bitmap, left: Int, top: Int,
            frame: Bitmap): List<List<List<Float>>> =
            detection.landmarks().map { points -> points.map { p ->
                listOf((left + p.x() * input.width) / frame.width,
                    (top + p.y() * input.height) / frame.height,
                    p.z() * input.width / frame.width,
                    minOf(p.visibility().orElse(0f), p.presence().orElse(1f)))
            } }

        /** 영역이 있으면 그 부분만 새 이미지로 잘라 내고, 원본 좌표로 되돌릴 왼쪽·위 위치를 함께 돌려줍니다. */
        private fun crop(frame: Bitmap, area: List<Double>?): Triple<Bitmap, Int, Int> {
            val left = area?.let { (it[0] * frame.width).toInt() } ?: 0
            val top = area?.let { (it[1] * frame.height).toInt() } ?: 0
            val right = area?.let { (it[2] * frame.width).roundToInt().coerceIn(left + 1, frame.width) } ?: frame.width
            val bottom = area?.let { (it[3] * frame.height).roundToInt().coerceIn(top + 1, frame.height) } ?: frame.height
            val input = if (area == null) frame else Bitmap.createBitmap(frame, left, top, right - left, bottom - top)
            return Triple(input, left, top)
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
            // 영역은 분석 입력에만 적용하며 결과 좌표는 원본 전체 화면으로 되돌립니다.
            val (input, left, top) = crop(frame, region)
            var managedImage: MPImage? = null
            try {
                checkActive()
                // SDK가 입력 이미지의 수명을 관리할 수 있으므로 미리보기는 먼저 만듭니다.
                val previewBytes = if (preview) ByteArrayOutputStream().use { bytes ->
                    frame.compress(Bitmap.CompressFormat.JPEG, 85, bytes)
                    bytes.toByteArray()
                } else null
                val start = SystemClock.elapsedRealtimeNanos()
                // 보조 모델은 MediaPipe가 입력 이미지를 정리하기 전에 먼저 실행합니다.
                // 보조 모델이 실패해도 기본 분석 결과는 그대로 쓸 수 있게 빈 결과로 넘어갑니다.
                val assistPoses = assist?.let { detector ->
                    try { mlKitPoses(detector, input, left, top, frame) } catch (error: Exception) {
                        android.util.Log.w("CruxPose", "보조 모델 실행 실패", error); emptyList()
                    }
                } ?: emptyList()
                val poses: List<List<List<Float>>> = if (engine == "mlkit_accurate") {
                    mlKitPoses(mlKit!!, input, left, top, frame)
                } else {
                    val image = BitmapImageBuilder(input).build()
                    managedImage = image
                    val detection = if (video && region == null) landmarker!!.detectForVideo(image, timeMs) else landmarker!!.detect(image)
                    mediaPipePoses(detection, input, left, top, frame)
                }
                val inferenceMs = (SystemClock.elapsedRealtimeNanos() - start) / 1000000.0
                checkActive()
                lastTime = timeMs
                val output = mutableMapOf<String, Any>("timeMs" to timeMs, "poses" to poses, "inferenceMs" to inferenceMs,
                    "appearances" to poses.map { torsoColors(frame, it) },
                    // 중복 제거와 채택은 Flutter에서 기본 결과와 비교해 결정합니다.
                    "assistPoses" to assistPoses, "assistAppearances" to assistPoses.map { torsoColors(frame, it) })
                if (previewBytes != null) output["preview"] = previewBytes
                return output
            } finally {
                managedImage?.close()
                if (input !== frame && !input.isRecycled) input.recycle()
                if (video && !frame.isRecycled) frame.recycle()
            }
        }

        /**
         * 놓친 프레임에서 예상 위치 주변만 잘라 크게 만든 뒤 두 모델로 다시 찾습니다.
         * 작은 사람이 크게 보여 검출이 쉬워집니다. 어떤 결과를 같은 사람으로 받을지는 Flutter가 정합니다.
         * 기본 분석과 다른 모델 객체를 써서 VIDEO 모드의 연속 추적 상태를 건드리지 않습니다.
         */
        fun refine(timeMs: Long, area: List<Double>): Map<String, Any> {
            checkActive()
            require(video && timeMs in 0 until durationMs) { "다시 찾을 시점이 영상 범위를 벗어났습니다." }
            val frame = readVideo(timeMs)
            val (input, left, top) = crop(frame, area)
            var managedImage: MPImage? = null
            try {
                checkActive()
                val detector = refineMlKit ?: PoseDetection.getClient(AccuratePoseDetectorOptions.Builder()
                    .setDetectorMode(AccuratePoseDetectorOptions.SINGLE_IMAGE_MODE).build()).also { refineMlKit = it }
                val mlKitResult = try { mlKitPoses(detector, input, left, top, frame) } catch (error: Exception) {
                    android.util.Log.w("CruxPose", "다시 찾기 보조 모델 실패", error); emptyList()
                }
                checkActive()
                // 확대 영역 안의 결과는 Flutter에서 위치·몸 크기·옷 색으로 한 번 더 거르므로
                // 기본 분석보다 낮은 기준을 써서 흐릿한 등진 자세도 후보로 받아 봅니다.
                val model = refineLandmarker ?: createLandmarker(RunningMode.IMAGE, 0.3f).also { refineLandmarker = it }
                val image = BitmapImageBuilder(input).build()
                managedImage = image
                val poses = mediaPipePoses(model.detect(image), input, left, top, frame) + mlKitResult
                checkActive()
                return mapOf("timeMs" to timeMs, "poses" to poses, "appearances" to poses.map { torsoColors(frame, it) })
            } finally {
                managedImage?.close()
                if (input !== frame && !input.isRecycled) input.recycle()
                if (!frame.isRecycled) frame.recycle()
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
            val helper = assist; assist = null
            val refineModel = refineLandmarker; refineLandmarker = null
            val refineDetector = refineMlKit; refineMlKit = null
            val decoder = retriever; retriever = null
            val image = photo; photo = null
            val first = firstFrame; firstFrame = null
            runCatching { model?.close() }
            runCatching { detector?.close() }
            runCatching { helper?.close() }
            runCatching { refineModel?.close() }
            runCatching { refineDetector?.close() }
            runCatching { decoder?.release() }
            if (image != null && !image.isRecycled) image.recycle()
            if (first != null && !first.isRecycled) first.recycle()
        }
    }

    /** 옷 색은 동일 인물 번호를 연결하는 보조 정보이며 이미지는 앱 밖으로 보내지 않습니다. */
    private fun torsoColors(frame: Bitmap, points: List<List<Float>>): List<Float> {
        val torso = listOf(11, 12, 23, 24).map { points[it] }
        if (torso.any { it[3] < 0.35f } || frame.isRecycled) return emptyList()
        val left = torso.minOf { it[0] }.coerceIn(0f, 1f)
        val right = torso.maxOf { it[0] }.coerceIn(0f, 1f)
        val top = torso.minOf { it[1] }.coerceIn(0f, 1f)
        val bottom = torso.maxOf { it[1] }.coerceIn(0f, 1f)
        if (right - left < 0.005f || bottom - top < 0.005f) return emptyList()
        val histogram = FloatArray(96)
        val hsv = FloatArray(3)
        // 몸통 중앙만 작게 읽어 주변 홀드와 배경 색이 섞이는 것을 줄입니다.
        for (row in 0 until 12) for (column in 0 until 12) {
            val x = ((left + (right - left) * (0.2f + 0.6f * (column + 0.5f) / 12)) * frame.width).toInt().coerceIn(0, frame.width - 1)
            val y = ((top + (bottom - top) * (0.2f + 0.6f * (row + 0.5f) / 12)) * frame.height).toInt().coerceIn(0, frame.height - 1)
            Color.colorToHSV(frame.getPixel(x, y), hsv)
            val hue = if (hsv[1] < 0.25f || hsv[2] < 0.2f) 0 else (hsv[0] / 45).toInt().coerceIn(0, 7)
            val saturation = if (hsv[1] < 0.25f) 0 else if (hsv[1] < 0.6f) 1 else 2
            val value = if (hsv[2] < 0.2f) 0 else if (hsv[2] < 0.45f) 1 else if (hsv[2] < 0.7f) 2 else 3
            histogram[(hue * 3 + saturation) * 4 + value] += 1f / 144
        }
        return histogram.toList()
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
