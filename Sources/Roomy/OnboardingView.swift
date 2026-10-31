import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: model.hasFullDiskAccess ? "lock.open.fill" : "lock.shield")
                .font(.system(size: 40))
                .foregroundStyle(model.hasFullDiskAccess ? Color.green : Color.accentColor)
            Text("Let Roomy see your whole disk").font(.title2.weight(.semibold))
            Text("macOS hides some folders, such as Mail, Messages and parts of Library, unless an app has Full Disk Access. Without it, Roomy still works, but those folders show as locked and are not counted.")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Click Open Privacy Settings.")
                Text("2. Turn on Roomy in the Full Disk Access list. If it is missing, click + and choose Roomy.")
                Text("3. Come back here. Roomy checks again when you return.")
            }
            .foregroundStyle(.secondary)
            Text("Roomy only reads file names and sizes. Nothing leaves your Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button("Continue Without") { model.dismissOnboarding() }
                Spacer()
                if model.hasFullDiskAccess {
                    Button("Done") { model.dismissOnboarding() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Open Privacy Settings") { model.openFullDiskAccessSettings() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(26)
        .frame(width: 480)
    }
}
