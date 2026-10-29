<div align="center">

<img src="docs/img/star.png" width="140" alt="Yokayo">

# Yokayo Music

**Открытый клиент Яндекс Музыки в стиле Apple Music — с ИИ-диджеем, который сводит треки прямо на телефоне**

[![Release](https://img.shields.io/github/v/release/ghostik707/yokayo-music?style=for-the-badge&color=4cc3ff&label=версия)](https://github.com/ghostik707/yokayo-music/releases/latest)
[![iOS](https://img.shields.io/badge/iOS-18%2B-3a5bff?style=for-the-badge&logo=apple&logoColor=white)](#-установка)
[![Swift](https://img.shields.io/badge/SwiftUI-orange?style=for-the-badge&logo=swift&logoColor=white)](ios)
[![License](https://img.shields.io/badge/лицензия-MIT-a46bff?style=for-the-badge)](LICENSE)

[**⬇️ Скачать IPA**](https://github.com/ghostik707/yokayo-music/releases/latest) · [**🌐 Сайт**](https://ghostik707.github.io/yokayo-music/) · [**🧠 BeatNet**](#-beatnet--своя-нейросеть)

</div>

<p align="center">
  <img src="docs/img/home-top.png" width="250" alt="Главная">
  &nbsp;
  <img src="docs/img/wave-top.png" width="250" alt="Моя волна">
  &nbsp;
  <img src="docs/img/eq.png" width="250" alt="Эквалайзер">
</p>

---

## ✨ Возможности

<table>
<tr>
<td width="50%" valign="top">

### 🎛️ ИИ-диджей
Треки сводятся в непрерывный сет: интро нового трека ложится на аутро старого, басы меняются на дропе, а если темпы не совпадают, старый трек уходит в эхо. В DJ-лаборатории можно свести два любых трека.

</td>
<td width="50%" valign="top">

### 🌊 Живая «Моя волна»
Карточка дышит в такт музыке, а при нажатии разлетается неоновыми волнами. Каждый запуск открывает новую сессию волны.

</td>
</tr>
<tr>
<td valign="top">

### 🎚️ Звук
Эквалайзер на 10 полос с пресетами и своим профилем. Ровная громкость −14 LUFS, кроссфейд, Sped up и Slowed + reverb. Качество задаётся отдельно для Wi‑Fi и мобильной сети.

</td>
<td valign="top">

### 🎤 Тексты караоке
Синхронные тексты с заливкой слов. Карточку со строкой можно сохранить для сторис.

</td>
</tr>
<tr>
<td valign="top">

### 📁 Своя музыка
Файлы MP3, FLAC, M4A и WAV из «Файлов». Свои плейлисты и добавление треков в плейлисты Яндекса.

</td>
<td valign="top">

### 📱 Система
Виджеты, Пункт управления, Siri и «Команды», обложка на весь экран блокировки, таймер сна, статистика прослушивания.

</td>
</tr>
</table>

## 🧠 BeatNet — своя нейросеть

Чтобы сводить по битам, нужно точно знать, где они. BeatNet — маленькая свёрточная сеть, обученная с нуля специально для Yokayo.

```
спектр 24 полосы ─▶ 8 расширяющихся свёрток ─▶ доли + сильные доли ─▶ темп и сетка тактов
                    (слышит ~12 с вокруг)
```

| | |
|---|---|
| Параметров | ≈ 31 тыс. |
| Анализ трека | ≈ 0,5 с на iPhone |
| Где работает | целиком на устройстве, через Accelerate |
| Веса | [`ios/YokayoMusic/Audio/BeatNet.bin`](ios/YokayoMusic/Audio/BeatNet.bin) |

Если сеть не уверена в сетке, она так и говорит. Тогда диджей не сводит по битам и меняет трек через эхо.

## 📦 Установка

1. Скачайте `YokayoMusic-x.y.ipa` из [последнего релиза](https://github.com/ghostik707/yokayo-music/releases/latest).
2. Установите через **eSign**, **AltStore** или **Sideloadly**.
3. Войдите в аккаунт Яндекса. Для полных треков нужна подписка Яндекс Плюс.

## 🛠️ Сборка

```bash
git clone https://github.com/ghostik707/yokayo-music.git
open yokayo-music/ios/YokayoMusic.xcodeproj
```

Нужен Xcode 26+. Зависимость [YM-API](https://github.com/p0rterB/YM-API) подтянется через Swift Package Manager. Соберите схему `YokayoMusic`.

## 🗂️ Структура

```
ios/        приложение для iPhone — SwiftUI, AVAudioEngine, виджеты
android/    версия для Android
docs/       сайт проекта (GitHub Pages)
```

## ⚖️ Дисклеймер

Yokayo Music — неофициальный клиент. Он не связан с Яндексом и Apple. Музыка воспроизводится по вашей подписке. В репозитории нет треков, взломов и обходов подписки, а приложение обращается только к серверам Яндекс Музыки.

## 📄 Лицензия

[MIT](LICENSE). Библиотека YM-API распространяется под своей лицензией (LGPL).

<div align="center"><sub>Сделано с любовью к музыке 💙</sub></div>
