package com.example.lumin

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.ToneGenerator
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.util.Base64
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.Locale

class MainActivity : FlutterActivity() {

    private val SERVICE_CHANNEL = "lumin/service"
    private val WAKE_CHANNEL = "lumin/wake"
    private val TTS_CHANNEL = "lumin/tts"
    private val SPEECH_CHANNEL = "lumin/native_speech"
    private var pendingWakeWordLaunch = false
    private var textToSpeech: TextToSpeech? = null
    private var speechRecognizer: SpeechRecognizer? = null
    private var ttsReady = false
    private var pendingTtsText: String? = null
    private val audioFocusChangeListener = AudioManager.OnAudioFocusChangeListener { }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pendingWakeWordLaunch = intent?.getBooleanExtra("fromWakeWord", false) == true
        initTextToSpeech()

        // Channel to START the wake word service
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SERVICE_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "startWakeWordService" -> {
                    val intent = Intent(this, WakeWordService::class.java)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(intent)
                    } else {
                        startService(intent)
                    }
                    result.success(null)
                }
                "stopWakeWordService" -> {
                    val intent = Intent(this, WakeWordService::class.java)
                    stopService(intent)
                    result.success(null)
                }
                "isWakeWordServiceRunning" -> {
                    result.success(WakeWordService.isRunning)
                }
                "canDrawOverlays" -> {
                    val canDraw = Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
                            Settings.canDrawOverlays(this)
                    result.success(canDraw)
                }
                "consumeWakeWordLaunch" -> {
                    val launchedFromWakeWord = pendingWakeWordLaunch ||
                            intent?.getBooleanExtra("fromWakeWord", false) == true
                    pendingWakeWordLaunch = false
                    intent?.removeExtra("fromWakeWord")
                    result.success(launchedFromWakeWord)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            TTS_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "speakArabic" -> {
                    val text = call.argument<String>("text").orEmpty()
                    result.success(if (text.isBlank()) false else speakArabic(text))
                }
                "beep" -> {
                    result.success(playBeep())
                }
                "openTtsSettings" -> {
                    openTtsSettings()
                    result.success(null)
                }
                "stop" -> {
                    textToSpeech?.stop()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SPEECH_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "recognize" -> {
                    val locale = call.argument<String>("locale") ?: "ar-EG"
                    recognizeSpeech(locale, result)
                }
                "measureMic" -> {
                    measureMic(result)
                }
                "recordWav" -> {
                    val durationMillis = call.argument<Int>("durationMillis") ?: 4000
                    recordWav(durationMillis, result)
                }
                "stop" -> {
                    stopNativeSpeech()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun measureMic(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED
        ) {
            result.success(mapOf("error" to "record_audio_permission_missing"))
            return
        }

        Thread {
            var recorder: AudioRecord? = null
            try {
                val sampleRate = 16000
                val minBuffer = AudioRecord.getMinBufferSize(
                    sampleRate,
                    AudioFormat.CHANNEL_IN_MONO,
                    AudioFormat.ENCODING_PCM_16BIT
                )
                if (minBuffer <= 0) {
                    runOnUiThread {
                        result.success(mapOf("error" to "bad_min_buffer:$minBuffer"))
                    }
                    return@Thread
                }

                val bufferSize = minBuffer * 2
                val audioRecord = AudioRecord(
                    MediaRecorder.AudioSource.MIC,
                    sampleRate,
                    AudioFormat.CHANNEL_IN_MONO,
                    AudioFormat.ENCODING_PCM_16BIT,
                    bufferSize
                )
                recorder = audioRecord

                audioRecord.startRecording()
                val buffer = ShortArray(bufferSize / 2)
                val deadline = System.currentTimeMillis() + 1200
                var maxAmplitude = 0
                var sampleCount = 0

                while (System.currentTimeMillis() < deadline) {
                    val read = audioRecord.read(buffer, 0, buffer.size)
                    if (read > 0) {
                        sampleCount += read
                        for (index in 0 until read) {
                            val amplitude = Math.abs(buffer[index].toInt())
                            if (amplitude > maxAmplitude) {
                                maxAmplitude = amplitude
                            }
                        }
                    }
                }

                audioRecord.stop()
                audioRecord.release()
                recorder = null

                runOnUiThread {
                    result.success(
                        mapOf(
                            "max" to maxAmplitude,
                            "samples" to sampleCount
                        )
                    )
                }
            } catch (error: Exception) {
                try {
                    recorder?.release()
                } catch (_: Exception) {}
                runOnUiThread {
                    result.success(
                        mapOf("error" to (error.message ?: error.javaClass.simpleName))
                    )
                }
            }
        }.start()
    }

    private fun recordWav(durationMillis: Int, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED
        ) {
            result.success(mapOf("error" to "record_audio_permission_missing"))
            return
        }

        Thread {
            var recorder: AudioRecord? = null
            try {
                val sampleRate = 16000
                val minBuffer = AudioRecord.getMinBufferSize(
                    sampleRate,
                    AudioFormat.CHANNEL_IN_MONO,
                    AudioFormat.ENCODING_PCM_16BIT
                )
                if (minBuffer <= 0) {
                    runOnUiThread {
                        result.success(mapOf("error" to "bad_min_buffer:$minBuffer"))
                    }
                    return@Thread
                }

                val bufferSize = minBuffer * 2
                val audioRecord = AudioRecord(
                    MediaRecorder.AudioSource.MIC,
                    sampleRate,
                    AudioFormat.CHANNEL_IN_MONO,
                    AudioFormat.ENCODING_PCM_16BIT,
                    bufferSize
                )
                recorder = audioRecord

                val pcm = ByteArrayOutputStream()
                val buffer = ByteArray(bufferSize)
                val deadline = System.currentTimeMillis() + durationMillis.coerceIn(1000, 10000)
                var maxAmplitude = 0

                audioRecord.startRecording()
                while (System.currentTimeMillis() < deadline) {
                    val read = audioRecord.read(buffer, 0, buffer.size)
                    if (read > 0) {
                        pcm.write(buffer, 0, read)
                        var index = 0
                        while (index + 1 < read) {
                            val sample = (buffer[index].toInt() and 0xff) or
                                    (buffer[index + 1].toInt() shl 8)
                            val amplitude = Math.abs(sample.toShort().toInt())
                            if (amplitude > maxAmplitude) {
                                maxAmplitude = amplitude
                            }
                            index += 2
                        }
                    }
                }

                audioRecord.stop()
                audioRecord.release()
                recorder = null

                val pcmBytes = pcm.toByteArray()
                val wavBytes = buildWav(pcmBytes, sampleRate)
                val audioBase64 = Base64.encodeToString(wavBytes, Base64.NO_WRAP)

                runOnUiThread {
                    result.success(
                        mapOf(
                            "audioBase64" to audioBase64,
                            "audioMimeType" to "audio/wav",
                            "max" to maxAmplitude
                        )
                    )
                }
            } catch (error: Exception) {
                try {
                    recorder?.release()
                } catch (_: Exception) {}
                runOnUiThread {
                    result.success(
                        mapOf("error" to (error.message ?: error.javaClass.simpleName))
                    )
                }
            }
        }.start()
    }

    private fun buildWav(pcm: ByteArray, sampleRate: Int): ByteArray {
        val out = ByteArrayOutputStream()
        val byteRate = sampleRate * 2
        val dataSize = pcm.size
        val riffSize = dataSize + 36

        fun writeAscii(value: String) {
            out.write(value.toByteArray(Charsets.US_ASCII))
        }

        fun writeIntLE(value: Int) {
            out.write(value and 0xff)
            out.write((value shr 8) and 0xff)
            out.write((value shr 16) and 0xff)
            out.write((value shr 24) and 0xff)
        }

        fun writeShortLE(value: Int) {
            out.write(value and 0xff)
            out.write((value shr 8) and 0xff)
        }

        writeAscii("RIFF")
        writeIntLE(riffSize)
        writeAscii("WAVE")
        writeAscii("fmt ")
        writeIntLE(16)
        writeShortLE(1)
        writeShortLE(1)
        writeIntLE(sampleRate)
        writeIntLE(byteRate)
        writeShortLE(2)
        writeShortLE(16)
        writeAscii("data")
        writeIntLE(dataSize)
        out.write(pcm)
        return out.toByteArray()
    }

    private fun recognizeSpeech(locale: String, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED
        ) {
            result.success(mapOf("error" to "record_audio_permission_missing"))
            return
        }

        if (!SpeechRecognizer.isRecognitionAvailable(this)) {
            result.success(mapOf("error" to "speech_recognizer_unavailable"))
            return
        }

        stopNativeSpeech()
        val recognizer = SpeechRecognizer.createSpeechRecognizer(this)
        speechRecognizer = recognizer
        var completed = false

        fun finish(payload: Map<String, String>) {
            if (completed) return
            completed = true
            try {
                recognizer.destroy()
            } catch (_: Exception) {}
            if (speechRecognizer === recognizer) {
                speechRecognizer = null
            }
            result.success(payload)
        }

        recognizer.setRecognitionListener(object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) {
                Log.d(TAG, "Native speech ready")
            }

            override fun onBeginningOfSpeech() {
                Log.d(TAG, "Native speech beginning")
            }

            override fun onRmsChanged(rmsdB: Float) {}
            override fun onBufferReceived(buffer: ByteArray?) {}
            override fun onEndOfSpeech() {
                Log.d(TAG, "Native speech end")
            }

            override fun onError(error: Int) {
                val name = speechErrorName(error)
                Log.e(TAG, "Native speech error=$name")
                finish(mapOf("error" to name))
            }

            override fun onResults(results: Bundle?) {
                val matches = results
                    ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                    .orEmpty()
                finish(mapOf("transcript" to matches.firstOrNull().orEmpty()))
            }

            override fun onPartialResults(partialResults: Bundle?) {}
            override fun onEvent(eventType: Int, params: Bundle?) {}
        })

        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(
                RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM
            )
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, locale)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_PREFERENCE, locale)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 3)
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_MINIMUM_LENGTH_MILLIS, 1000)
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, 2500)
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS, 1800)
        }

        try {
            recognizer.startListening(intent)
        } catch (error: Exception) {
            Log.e(TAG, "Native speech start failed: ${error.message}")
            finish(mapOf("error" to "start_failed:${error.message.orEmpty()}"))
        }
    }

    private fun stopNativeSpeech() {
        try {
            speechRecognizer?.cancel()
        } catch (_: Exception) {}
        try {
            speechRecognizer?.destroy()
        } catch (_: Exception) {}
        speechRecognizer = null
    }

    private fun speechErrorName(error: Int): String =
        when (error) {
            SpeechRecognizer.ERROR_AUDIO -> "error_audio"
            SpeechRecognizer.ERROR_CLIENT -> "error_client"
            SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "error_insufficient_permissions"
            SpeechRecognizer.ERROR_NETWORK -> "error_network"
            SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "error_network_timeout"
            SpeechRecognizer.ERROR_NO_MATCH -> "error_no_match"
            SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "error_recognizer_busy"
            SpeechRecognizer.ERROR_SERVER -> "error_server"
            SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "error_speech_timeout"
            else -> "error_$error"
        }

    private fun initTextToSpeech() {
        if (textToSpeech != null) {
            return
        }

        textToSpeech = TextToSpeech(this, { status ->
            ttsReady = status == TextToSpeech.SUCCESS
            if (ttsReady) {
                Log.d(TAG, "TTS initialized")
                Log.d(TAG, "TTS engine=${textToSpeech?.defaultEngine}")
                val languageResult = textToSpeech?.setLanguage(Locale("ar", "EG"))
                if (languageResult == TextToSpeech.LANG_MISSING_DATA ||
                    languageResult == TextToSpeech.LANG_NOT_SUPPORTED
                ) {
                    Log.w(TAG, "Arabic Egypt TTS missing/unsupported, trying Arabic")
                    textToSpeech?.setLanguage(Locale("ar"))
                }
                textToSpeech?.setSpeechRate(0.9f)
                textToSpeech?.setPitch(1.0f)
                logArabicVoices()
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                    textToSpeech?.setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_MEDIA)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                            .build()
                    )
                }
                textToSpeech?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                    override fun onStart(utteranceId: String?) {
                        Log.d(TAG, "TTS started: $utteranceId")
                    }

                    override fun onDone(utteranceId: String?) {
                        Log.d(TAG, "TTS done: $utteranceId")
                    }

                    @Deprecated("Deprecated in Java")
                    override fun onError(utteranceId: String?) {
                        Log.e(TAG, "TTS error: $utteranceId")
                    }

                    override fun onError(utteranceId: String?, errorCode: Int) {
                        Log.e(TAG, "TTS error: $utteranceId code=$errorCode")
                    }
                })

                pendingTtsText?.let {
                    pendingTtsText = null
                    speakArabic(it)
                }
            } else {
                Log.e(TAG, "TTS initialization failed: $status")
            }
        }, GOOGLE_TTS_ENGINE)
    }

    private fun logArabicVoices() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP) {
            return
        }

        try {
            val arabicVoices = textToSpeech?.voices
                ?.filter { it.locale.language == "ar" }
                ?.joinToString { "${it.name}/${it.locale}" }
                .orEmpty()
            Log.d(TAG, "Arabic TTS voices: ${arabicVoices.ifBlank { "none" }}")
        } catch (error: Exception) {
            Log.w(TAG, "Could not list TTS voices: ${error.message}")
        }
    }

    private fun speakArabic(text: String): Boolean {
        initTextToSpeech()
        val engine = textToSpeech ?: return false
        if (!ttsReady) {
            pendingTtsText = text
            Log.d(TAG, "TTS not ready yet, queued answer")
            return true
        }

        engine.stop()
        val audioManager = getSystemService(AUDIO_SERVICE) as AudioManager
        audioManager.mode = AudioManager.MODE_NORMAL
        @Suppress("DEPRECATION")
        audioManager.requestAudioFocus(
            audioFocusChangeListener,
            AudioManager.STREAM_MUSIC,
            AudioManager.AUDIOFOCUS_GAIN_TRANSIENT
        )
        Log.d(
            TAG,
            "Media volume=${audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)}/" +
                    audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        )

        val params = Bundle().apply {
            putFloat(TextToSpeech.Engine.KEY_PARAM_VOLUME, 1.0f)
            putString(TextToSpeech.Engine.KEY_PARAM_UTTERANCE_ID, "lumin-answer")
            putInt(TextToSpeech.Engine.KEY_PARAM_STREAM, AudioManager.STREAM_MUSIC)
        }
        val result = engine.speak(text, TextToSpeech.QUEUE_FLUSH, params, "lumin-answer")
        Log.d(TAG, "TTS speak result=$result text=$text")
        return result == TextToSpeech.SUCCESS
    }

    private fun playBeep(): Boolean {
        return try {
            val audioManager = getSystemService(AUDIO_SERVICE) as AudioManager
            Log.d(
                TAG,
                "Beep media volume=${audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)}/" +
                        audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
            )
            ToneGenerator(AudioManager.STREAM_MUSIC, 100).startTone(ToneGenerator.TONE_PROP_BEEP, 350)
            true
        } catch (error: Exception) {
            Log.e(TAG, "Beep failed: ${error.message}")
            false
        }
    }

    private fun openTtsSettings() {
        try {
            startActivity(Intent("com.android.settings.TTS_SETTINGS"))
        } catch (_: Exception) {
            startActivity(Intent(Settings.ACTION_SETTINGS))
        }
    }

    // VERY IMPORTANT
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)

        if (intent.getBooleanExtra("fromWakeWord", false)) {
            pendingWakeWordLaunch = true
            MethodChannel(
                flutterEngine!!.dartExecutor.binaryMessenger,
                WAKE_CHANNEL
            ).invokeMethod("wakeWordDetected", null)
        }
    }

    override fun onDestroy() {
        stopNativeSpeech()
        textToSpeech?.stop()
        textToSpeech?.shutdown()
        textToSpeech = null
        super.onDestroy()
    }

    companion object {
        private const val TAG = "LuminMainActivity"
        private const val GOOGLE_TTS_ENGINE = "com.google.android.tts"
    }
}
