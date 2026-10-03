package com.cruxcam.crux_cam

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var poseBridge: PoseBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        poseBridge = PoseBridge(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        // 화면과 엔진이 종료될 때 작업 큐와 모델도 함께 정리합니다.
        poseBridge?.dispose()
        poseBridge = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
