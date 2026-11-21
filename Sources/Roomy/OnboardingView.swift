import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: model.hasFullDiskAccess ? "lock.open.fill" : "lock.shield")
                .font(.system(size: 40))
                .foregroundStyle(model.hasFullDiskAccess ? Color.green : Color.accentColor)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: model.hasFullDiskAccess)
                .entrance(offset: 0, scale: 0.6)
            Text("Let Roomy see your whole disk").font(.title2.weight(.semibold))
                .entrance(index: 1, offset: 10)
            Text("macOS hides some folders, such as Mail, Messages and parts of Library, unless an app has Full Disk Access. Without it, Roomy still works, but those folders show as locked and are not counted.")
                .fixedSize(horizontal: false, vertical: true)
                .entrance(index: 2, offset: 10)
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Click Open Privacy Settings.")
                Text("2. Turn on Roomy in the Full Disk Access list. If it is missing, click + and choose Roomy.")
                Text("3. Come back here. Roomy checks again when you return.")
            }
            .foregroundStyle(.secondary)
            .entrance(index: 3, offset: 10)
            Text("Roomy only reads file names and sizes. Nothing leaves your Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .entrance(index: 4, offset: 10)
            HStack {
                Button("Continue Without") { model.dismissOnboarding() }
                Spacer()
                if model.hasFullDiskAccess {
                    Button("Done") { model.dismissOnboarding() }.keyboardShortcut(.defaultAction)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                } else {
                    Button("Open Privacy Settings") { model.openFullDiskAccessSettings() }.keyboardShortcut(.defaultAction)
                        .transition(.opacity)
                }
            }
            .entrance(index: 5, offset: 10)
        }
        .padding(26)
        .frame(width: 480)
        .motion(Motion.spring, value: model.hasFullDiskAccess)
    }
}
