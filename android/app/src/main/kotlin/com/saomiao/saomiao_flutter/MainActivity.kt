package com.saomiao.saomiao_flutter

import android.graphics.BitmapFactory
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val ocrExecutor = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.saomiao.saomiao_flutter/ocr"
        ).setMethodCallHandler { call, result ->
            if (call.method != "recognizeText") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val bytes = call.argument<ByteArray>("bytes")
            if (bytes == null || bytes.isEmpty()) {
                result.error("INVALID_IMAGE", "图片数据为空", null)
                return@setMethodCallHandler
            }
            ocrExecutor.execute {
                try {
                    val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                    if (bitmap == null || bitmap.width <= 0 || bitmap.height <= 0) {
                        runOnUiThread { result.error("DECODE_FAILED", "无法解码图片进行文字识别", null) }
                        return@execute
                    }
                    val imgW = bitmap.width.toDouble()
                    val imgH = bitmap.height.toDouble()
                    val inputImage = InputImage.fromBitmap(bitmap, 0)
                    val recognizer = TextRecognition.getClient(
                        ChineseTextRecognizerOptions.Builder().build()
                    )
                    recognizer.process(inputImage)
                        .addOnSuccessListener { visionText ->
                            val lines = ArrayList<Map<String, Any>>()
                            for (block in visionText.textBlocks) {
                                for (line in block.lines) {
                                    val box = line.boundingBox
                                    val lineText = line.text.trim()
                                    if (lineText.isEmpty() || box == null) continue
                                    lines.add(
                                        mapOf(
                                            "text" to lineText,
                                            "left" to (box.left / imgW).coerceIn(0.0, 1.0),
                                            "top" to (box.top / imgH).coerceIn(0.0, 1.0),
                                            "right" to (box.right / imgW).coerceIn(0.0, 1.0),
                                            "bottom" to (box.bottom / imgH).coerceIn(0.0, 1.0)
                                        )
                                    )
                                }
                            }
                            val payload = mapOf(
                                "text" to visionText.text.trim(),
                                "lines" to lines
                            )
                            recognizer.close()
                            bitmap.recycle()
                            runOnUiThread { result.success(payload) }
                        }
                        .addOnFailureListener { err ->
                            recognizer.close()
                            bitmap.recycle()
                            runOnUiThread {
                                result.error("OCR_FAILED", err.localizedMessage ?: "文字识别失败", null)
                            }
                        }
                } catch (err: Exception) {
                    runOnUiThread {
                        result.error("OCR_ERROR", err.localizedMessage ?: "文字识别异常", null)
                    }
                }
            }
        }
    }

    override fun onDestroy() {
        ocrExecutor.shutdown()
        super.onDestroy()
    }
}
