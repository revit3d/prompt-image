import Photos
import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var photoAccess = PhotoLibraryAccess()
    @State private var showsSettingsError = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 44))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text("PromptImage")
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text("Поиск по вашим фотографиям")
                        .font(.title2)
                }

                VStack(alignment: .leading, spacing: 16) {
                    permissionContent
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 20))

                Label {
                    Text("Приложение не отправляет ваши фотографии на сервер и не изменяет медиатеку.")
                } icon: {
                    Image(systemName: "lock.shield")
                        .accessibilityHidden(true)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                photoAccess.refresh()
            }
        }
        .alert("Не удалось открыть настройки", isPresented: $showsSettingsError) {
            Button("Понятно", role: .cancel) { }
        } message: {
            Text("Откройте «Настройки» → «Приложения» → PromptImage → «Фото», чтобы изменить доступ.")
        }
    }

    @ViewBuilder
    private var permissionContent: some View {
        switch photoAccess.status {
        case .notDetermined:
            permissionHeading("Подключите медиатеку")
            Text("PromptImage нужен доступ к фотографиям для поиска по описанию. Вы можете разрешить доступ ко всей медиатеке или только к выбранным снимкам.")
            Button {
                Task { await photoAccess.requestAccess() }
            } label: {
                HStack {
                    if photoAccess.isRequesting {
                        ProgressView()
                    }
                    Text(photoAccess.isRequesting ? "Ожидаем разрешение…" : "Продолжить")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(photoAccess.isRequesting)
            .accessibilityIdentifier("requestPhotoAccess")

        case .authorized:
            permissionHeading("Полный доступ разрешён")
            Text("Приложению доступны фотографии из всей медиатеки. Вы можете изменить разрешение в настройках iOS.")
            settingsButton("Изменить доступ")

        case .limited:
            permissionHeading("Доступ к выбранным фотографиям")
            Text("Приложению доступны только снимки, которые вы выбрали. Изменить выбор или разрешить полный доступ можно в настройках iOS.")
            settingsButton("Изменить доступ")

        case .denied:
            permissionHeading("Доступ к фотографиям закрыт")
            Text("Чтобы подключить медиатеку, откройте настройки iOS и разрешите доступ ко всем или выбранным фотографиям.")
            settingsButton("Открыть настройки")

        case .restricted:
            permissionHeading("Доступ ограничен системой")
            Text("Разрешение недоступно из-за системных ограничений, например «Экранного времени» или управления устройством.")

        @unknown default:
            permissionHeading("Не удалось определить доступ")
            Text("Попробуйте проверить разрешение ещё раз.")
            Button("Проверить снова") {
                photoAccess.refresh()
            }
            .buttonStyle(.bordered)
        }
    }

    private func permissionHeading(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("photoAccessStatus")
    }

    private func settingsButton(_ title: String) -> some View {
        Button(title) {
            guard let url = URL(string: UIApplication.openSettingsURLString) else {
                showsSettingsError = true
                return
            }
            openURL(url) { accepted in
                showsSettingsError = !accepted
            }
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("openPhotoSettings")
    }
}

#Preview {
    ContentView()
}
