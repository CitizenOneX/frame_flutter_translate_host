# frame_flutter_translate_host (offline speech-to-text, live captioning, offline translation, subtitles)

Connects to Frame and streams audio from its microphone, which is sent through a local (on Host device) [Vosk speech-to-text engine (Flutter package is Android only)](https://pub.dev/packages/vosk_flutter), translates the text into a target language on-device using [ML Kit (Android, iOS only)](https://pub.dev/packages/google_mlkit_translation), and displays the translated text on the Frame display.

Drop in an alternative [Vosk model](https://alphacephei.com/vosk/models) to perform speech-to-text in a language other than English (`vosk-model-small-en-us-0.15` included).

Specify an alternative `targetLanguage` in [lib/main.dart](lib/main.dart) to translate to an [ML Kit supported language](https://developers.google.com/ml-kit/language/translation/translation-language-support) other than Spanish.

Note: Frame may not support the display of characters from all languages out of the box.

### Architecture
![Architecture](docs/Frame%20App%20Architecture%20-%20Translate%20Host.svg)

### See Also
- [Frame Flutter Speech-To-Text Host](https://github.com/CitizenOneX/frame_flutter_stt_host)
- [Frame Flutter Hello World](https://github.com/CitizenOneX/frame_flutter_helloworld)