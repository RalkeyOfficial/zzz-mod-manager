# 🪟 Інструкція: Збірка для Windows

## ⚠️ Важливо
Flutter **НЕ підтримує cross-compilation** для Windows з Linux. Потрібна Windows машина або віртуальна машина.

---

## 📋 Варіанти збірки

### 🎯 Варіант 1: Windows машина (Рекомендовано)

#### Передумови:
- Windows 10/11 (x64)
- Flutter SDK 3.8.1+ 
- Git
- (Опціонально) Inno Setup 6 для installer

#### Крок 1: Встановити Flutter

```powershell
# Завантажити Flutter SDK
# https://docs.flutter.dev/get-started/install/windows

# Додати Flutter до PATH
# Перевірити установку:
flutter doctor
```

#### Крок 2: Клонувати проект

```powershell
git clone https://github.com/NotionMe/Mod-manager.git
cd Mod-manager
```

#### Крок 3: Встановити залежності

```powershell
cd mod_manager_flutter
flutter pub get
cd ..
```

#### Крок 4: Вибрати тип збірки

---

### 🔨 А) Проста збірка (Raw Build)

**Найпростіший варіант - просто executable та DLL файли**

```powershell
cd mod_manager_flutter
flutter build windows --release
```

**Результат:**
```
mod_manager_flutter\build\windows\x64\runner\Release\
├── mod_manager_flutter.exe   ← Головний файл
├── data\
├── *.dll файли
└── інші файли
```

**Використання:**
- Просто запусти `mod_manager_flutter.exe`
- Для поширення скопіюй всю папку `Release`

---

### 📦 Б) Portable ZIP версія

**Створює ZIP архів з README та батніком для запуску з правами адміна**

```powershell
# З кореневої директорії проекту
.\windows_installer\build_portable.ps1 -Version "2.2.2"
```

**Що включає скрипт:**
1. Білдить Flutter додаток
2. Копіює всі файли
3. Додає іконку
4. Створює README.txt з інструкціями
5. Створює `Run_As_Admin.bat` для легкого запуску з правами адміна
6. Пакує все в ZIP

**Результат:**
```
windows_installer\output\
└── ZZZ-Mod-Manager-Portable-2.2.2.zip
```

**Переваги:**
- ✅ Не потребує установки
- ✅ Можна запускати з флешки
- ✅ Легко поширювати
- ✅ Включає батнік для запуску з правами адміна

**Для користувача:**
1. Розпакувати ZIP
2. Запустити `Run_As_Admin.bat` або `mod_manager_flutter.exe`

---

### 🎁 В) Installer (Inno Setup)

**Створює професійний Windows installer з деінсталером**

#### Крок 1: Встановити Inno Setup

Завантаж та встанови [Inno Setup 6](https://jrsoftware.org/isdl.php)

#### Крок 2: Запустити скрипт

```powershell
# З кореневої директорії проекту
.\windows_installer\build_installer.bat
```

**Що включає скрипт:**
1. Білдить Flutter додаток
2. Перевіряє наявність Inno Setup
3. Компілює installer через `setup.iss`

**Результат:**
```
windows_installer\output\
└── ZZZ-Mod-Manager-Setup-2.2.2.exe
```

**Переваги:**
- ✅ Професійний вигляд
- ✅ Автоматична установка в Program Files
- ✅ Створення ярликів (Desktop, Start Menu)
- ✅ Деінсталер в Control Panel
- ✅ Підтримка української мови
- ✅ Перевірка Windows 10+

**Для користувача:**
1. Запустити Setup.exe
2. Слідувати інструкціям
3. Програма встановиться автоматично

---

### ☁️ Варіант 2: GitHub Actions (Автоматична збірка)

**Для автоматичної збірки при кожному релізі**

#### Що вже є:

Файл `.github/workflows/build-windows.yml` вже створено!

#### Як використовувати:

**Варіант А: Ручний запуск**

1. Іди на GitHub → Actions
2. Вибери "Build Windows Release"
3. Натисни "Run workflow"
4. Скачай готовий ZIP з Artifacts

**Варіант Б: Автоматично при тегу**

```bash
# Створи git tag
git tag v2.2.2
git push origin v2.2.2

# GitHub Actions автоматично:
# 1. Зібере Windows версію
# 2. Створить Portable ZIP
# 3. Завантажить як Release на GitHub
```

#### Переваги GitHub Actions:
- ✅ Не потребує Windows машини
- ✅ Автоматична збірка
- ✅ Завантаження в GitHub Releases
- ✅ Безкоштовно для публічних репо

---

### 🐳 Варіант 3: Windows VM на Linux

**Якщо хочеш білдити локально з Linux**

#### Крок 1: Встановити VirtualBox

```bash
sudo pacman -S virtualbox
```

#### Крок 2: Створити Windows VM

1. Завантаж [Windows 10/11 ISO](https://www.microsoft.com/software-download/windows11)
2. Створи нову VM в VirtualBox
3. Встанови Windows
4. Встанови Flutter на Windows VM
5. Збери проект в VM

#### Переваги:
- ✅ Локальна збірка
- ✅ Повний контроль
- ✅ Можна тестувати на Windows

#### Мінуси:
- ❌ Потребує багато ресурсів (RAM, CPU)
- ❌ Складніше налаштувати

---

## 📊 Порівняння варіантів

| Метод | Складність | Швидкість | Потребує Windows | Автоматизація |
|-------|-----------|----------|------------------|---------------|
| Windows машина | 🟢 Легко | 🟢 Швидко | ✅ Так | ❌ Ручна |
| GitHub Actions | 🟢 Легко | 🟡 Середньо | ❌ Ні | ✅ Авто |
| Windows VM | 🔴 Складно | 🔴 Повільно | ❌ Ні | 🟡 Напівавто |

---

## 🎯 Рекомендації

**Для розробки:**
- Використовуй Windows машину або VM
- Тестуй на реальній Windows системі

**Для релізів:**
- Використовуй GitHub Actions
- Автоматичні білди при кожному тегу

**Для розповсюдження:**
- **Portable ZIP** - найлегше для користувачів
- **Installer** - професійніший вигляд

---

## ❓ Часті питання

**Q: Чи можна зібрати Windows версію на Linux?**
A: Ні, Flutter не підтримує cross-compilation. Потрібна Windows або GitHub Actions.

**Q: Який формат краще - Portable чи Installer?**
A: Portable простіший для користувачів. Installer виглядає професійніше.

**Q: Чи працює збірка на Wine?**
A: Ні, Flutter Windows desktop не працює на Wine.

**Q: Скільки займає Windows збірка?**
A: ~50-80 MB в стиснутому вигляді (ZIP).

**Q: Чи потрібні права адміна?**
A: Так, для створення симлінків на Windows потрібні права адміністратора.

---

## 📝 Наступні кроки

1. Вибери варіант збірки
2. Зібери проект
3. Протестуй на Windows 10/11
4. Опублікуй на GitHub Releases або GameBanana
5. Насолоджуйся! 🎉

---

## 🔗 Корисні посилання

- [Flutter Windows Setup](https://docs.flutter.dev/get-started/install/windows)
- [Inno Setup Download](https://jrsoftware.org/isdl.php)
- [GitHub Actions Docs](https://docs.github.com/en/actions)
- [Windows 11 ISO](https://www.microsoft.com/software-download/windows11)

---

**Автор:** NotionMe  
**GitHub:** https://github.com/NotionMe/Mod-manager  
**Ліцензія:** MIT
