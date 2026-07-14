import Foundation
import Testing
@testable import Resizer

@Suite("Localization catalog")
struct LocalizationTests {
    private let russian = Locale(identifier: "ru")

    @Test("The application bundle contains English and Russian localizations")
    func bundledLanguages() {
        let localizations = Set(Bundle.main.localizations)

        #expect(localizations.contains("en"))
        #expect(localizations.contains("ru"))
    }

    @Test("Representative static and computed strings are translated")
    func representativeTranslations() {
        #expect(localized("Queue", localization: "en") == "Queue")
        #expect(localized("Queue", localization: "ru") == "Очередь")
        #expect(
            localized("Add Videos…", localization: "ru")
                == "Добавить видео…"
        )
        #expect(
            localized("Preparing compression…", localization: "ru")
                == "Подготовка к сжатию…"
        )
        #expect(
            localized(
                "Choose an output folder before starting.",
                localization: "ru"
            ) == "Перед запуском выберите папку результата."
        )
        #expect(
            localized("Add a number", localization: "ru")
                == "Добавить номер"
        )
        #expect(
            localized("Resizer couldn’t start", localization: "ru")
                == "Не удалось запустить Resizer"
        )
        #expect(
            String(
                format: localized("Version %@ (%@)", localization: "ru"),
                locale: russian,
                "1.2",
                "42"
            ) == "Версия 1.2 (42)"
        )
        #expect(
            String(
                format: localized("%@ / No audio", localization: "ru"),
                locale: russian,
                "H.264"
            ) == "H.264 / без аудио"
        )
    }

    @Test("Safety failure guidance is translated into Russian")
    func safetyFailureGuidance() {
        let expectedTranslations = [
            (
                "The source video is no longer available. Select it again and retry.",
                "Исходное видео больше недоступно. Выберите его снова и повторите попытку."
            ),
            (
                "The output folder is unavailable. Reconnect the disk or choose another folder.",
                "Папка результата недоступна. Подключите диск снова или выберите другую папку."
            ),
            (
                "The intended output name is already in use. Choose automatic numbering or another folder.",
                "Файл с выбранным именем уже существует. Включите автоматическую нумерацию или выберите другую папку."
            ),
            (
                "This output disk cannot publish files safely. Choose another folder.",
                "На выбранном диске невозможно безопасно сохранить итоговый файл. Выберите другую папку."
            ),
            (
                "There is not enough free space in the output folder. Free some space and retry.",
                "В папке результата недостаточно свободного места. Освободите место и повторите попытку."
            ),
            (
                "The bundled video tool stopped unexpectedly. Retry or open Diagnostics for technical details.",
                "Встроенный видеоинструмент неожиданно остановился. Повторите попытку или откройте «Диагностику» для технических подробностей."
            )
        ]

        for (key, expected) in expectedTranslations {
            #expect(localized(key, localization: "ru") == expected)
        }
    }

    @Test("Count-dependent queue strings use Russian plural rules")
    func russianPluralForms() {
        #expect(sessionVideoCount(1) == "1 видео в этой сессии")
        #expect(sessionVideoCount(2) == "2 видео в этой сессии")
        #expect(sessionVideoCount(5) == "5 видео в этой сессии")
        #expect(maximumLength(1) == "Максимальная длина: 1 символ.")
        #expect(maximumLength(2) == "Максимальная длина: 2 символа.")
        #expect(maximumLength(5) == "Максимальная длина: 5 символов.")
    }

    @Test("Diagnostics and bundled license labels are translated")
    func diagnosticAndLicenseTranslations() {
        #expect(
            localized("Resizer diagnostic report", localization: "ru")
                == "Диагностический отчёт Resizer"
        )
        #expect(
            localized(
                "Paths and filenames are redacted.",
                localization: "ru"
            ) == "Пути и имена файлов скрыты."
        )
        #expect(
            localized("Third-party notices", localization: "ru")
                == "Уведомления о сторонних компонентах"
        )
        #expect(
            localized("GNU LGPL 2.1 license", localization: "ru")
                == "Лицензия GNU LGPL 2.1"
        )
    }

    private func localized(_ key: String, localization: String) -> String {
        guard let path = Bundle.main.path(
            forResource: localization,
            ofType: "lproj"
        ), let bundle = Bundle(path: path) else {
            return "Missing localization: \(localization)"
        }
        return bundle.localizedString(
            forKey: key,
            value: nil,
            table: "Localizable"
        )
    }

    private func sessionVideoCount(_ count: Int) -> String {
        let format = localized(
            "%lld videos this session",
            localization: "ru"
        )
        return String(format: format, locale: russian, Int64(count))
    }

    private func maximumLength(_ count: Int) -> String {
        let format = localized(
            "Use no more than %lld characters.",
            localization: "ru"
        )
        return String(format: format, locale: russian, Int64(count))
    }
}
