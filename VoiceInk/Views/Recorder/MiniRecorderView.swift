import SwiftUI

struct MiniRecorderView<S: RecorderStateProvider & ObservableObject>: View {
    @ObservedObject var stateProvider: S
    @ObservedObject var recorder: Recorder
    let onRecordButtonTapped: () -> Void
    let onCloseTapped: () -> Void
    @AppStorage(RecorderDisplaySettingsKeys.showLiveTranscript) private var showLiveTranscript = false

    private let controlBarHeight: CGFloat = 40
    private let compactWidth: CGFloat = 184
    private let expandedWidth: CGFloat = 300
    private let compactCornerRadius: CGFloat = 20
    private let expandedCornerRadius: CGFloat = 14

    private var hasLiveTranscript: Bool {
        Self.shouldShowLiveTranscript(
            showLiveTranscript: showLiveTranscript,
            recordingState: stateProvider.recordingState,
            partialTranscript: stateProvider.partialTranscript
        )
    }

    static func shouldShowLiveTranscript(
        showLiveTranscript: Bool,
        recordingState: RecordingState,
        partialTranscript: String
    ) -> Bool {
        showLiveTranscript &&
            recordingState == .recording &&
            !partialTranscript.isEmpty
    }

    private var controlBar: some View {
        HStack(spacing: 0) {
            RecorderRecordButton(
                recordingState: stateProvider.recordingState,
                action: onRecordButtonTapped
            )
            .padding(.leading, 10)

            Spacer(minLength: 0)

            RecorderStatusDisplay(
                currentState: stateProvider.recordingState,
                audioMeter: recorder.audioMeter
            )

            Spacer(minLength: 0)

            RecorderCloseButton(action: onCloseTapped)
                .padding(.trailing, 10)
        }
        .frame(height: controlBarHeight)
    }

    var body: some View {
        VStack(spacing: 0) {
            if hasLiveTranscript {
                LiveTranscriptView(text: stateProvider.partialTranscript)
                Divider().background(Color.white.opacity(0.15))
            }
            controlBar
        }
        .frame(width: hasLiveTranscript ? expandedWidth : compactWidth)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: hasLiveTranscript ? expandedCornerRadius : compactCornerRadius, style: .continuous))
        .animation(.easeInOut(duration: 0.3), value: hasLiveTranscript)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}
