import SwiftUI

struct RecorderRecordButton: View {
    let recordingState: RecordingState
    let action: () -> Void

    private var visualState: VisualState {
        switch recordingState {
        case .idle, .busy:
            return .ready
        case .starting, .recording:
            return .recording
        case .transcribing, .enhancing:
            return .processing
        }
    }

    private var isDisabled: Bool {
        Self.isDisabled(for: recordingState)
    }

    static func isDisabled(for state: RecordingState) -> Bool {
        switch state {
        case .idle, .recording:
            return false
        case .starting, .transcribing, .enhancing, .busy:
            return true
        }
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(colors.surface)
                    .overlay(Circle().strokeBorder(colors.border, lineWidth: 0.6))

                stateMark
            }
            .frame(width: 21, height: 21)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(accessibilityLabel)
        .accessibilityLabel(Text(accessibilityLabel))
    }

    private var colors: StateColors {
        switch visualState {
        case .ready:
            return StateColors(
                surface: Color(red: 0.30, green: 0.30, blue: 0.32),
                border: Color(red: 0.42, green: 0.42, blue: 0.44),
                mark: Color(red: 0.78, green: 0.78, blue: 0.80)
            )
        case .recording:
            return StateColors(
                surface: AppTheme.Status.error.opacity(0.92),
                border: AppTheme.Status.error.opacity(0.98),
                mark: .white
            )
        case .processing:
            return StateColors(
                surface: Color.white.opacity(0.13),
                border: Color.white.opacity(0.18),
                mark: Color.white.opacity(0.86)
            )
        }
    }

    @ViewBuilder
    private var stateMark: some View {
        switch visualState {
        case .ready, .recording:
            RoundedRectangle(cornerRadius: 2.2, style: .continuous)
                .fill(colors.mark)
                .frame(width: 8, height: 8)
        case .processing:
            ProcessingIndicator(color: colors.mark)
        }
    }

    private var accessibilityLabel: String {
        Self.accessibilityLabel(for: recordingState)
    }

    static func accessibilityLabel(for state: RecordingState) -> String {
        switch state {
        case .idle:
            return String(localized: "Start recording")
        case .starting:
            return String(localized: "Starting recording")
        case .recording:
            return String(localized: "Stop recording")
        case .transcribing:
            return String(localized: "Transcribing recording")
        case .enhancing:
            return String(localized: "Processing recording")
        case .busy:
            return String(localized: "Recorder unavailable")
        }
    }

    private enum VisualState: Equatable {
        case ready
        case recording
        case processing
    }

    private struct StateColors {
        let surface: Color
        let border: Color
        let mark: Color
    }
}

struct RecorderCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.13))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.6))

                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white.opacity(0.86))
            }
            .frame(width: 21, height: 21)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Close")
    }
}

struct ProcessingIndicator: View {
    @State private var rotation: Double = 0
    let color: Color

    var body: some View {
        Circle()
            .trim(from: 0.1, to: 0.9)
            .stroke(color, lineWidth: 1.5)
            .frame(width: 12, height: 12)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}

@MainActor
struct ProgressAnimation: View {
    let color: Color
    let animationSpeed: Double

    private let dotCount = 5
    private let dotSize: CGFloat = 3
    private let dotSpacing: CGFloat = 2

    @State private var currentDot = 0
    @State private var timer: Timer?

    init(color: Color = .white, animationSpeed: Double = 0.3) {
        self.color = color
        self.animationSpeed = animationSpeed
    }

    var body: some View {
        HStack(spacing: dotSpacing) {
            ForEach(0..<dotCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: dotSize / 2)
                    .fill(color.opacity(index <= currentDot ? 0.85 : 0.25))
                    .frame(width: dotSize, height: dotSize)
            }
        }
        .onAppear { startAnimation() }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }

    private func startAnimation() {
        timer?.invalidate()
        currentDot = 0
        timer = Timer.scheduledTimer(withTimeInterval: animationSpeed, repeats: true) { _ in
            MainActor.assumeIsolated {
                currentDot = (currentDot + 1) % (dotCount + 2)
                if currentDot > dotCount { currentDot = -1 }
            }
        }
    }
}

struct LiveTranscriptView: View {
    let text: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .id("bottom")
            }
            .frame(height: 56)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .black, location: 0.18),
                        .init(color: .black, location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .onChange(of: text) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
        .transaction { $0.disablesAnimations = true }
    }
}

struct RecorderStatusDisplay: View {
    let currentState: RecordingState
    let audioMeter: AudioMeter

    var body: some View {
        Group {
            if currentState == .transcribing || currentState == .enhancing {
                ProcessingStatusDisplay(color: .white).transition(.opacity)
            } else if currentState == .recording {
                AudioVisualizer(audioMeter: audioMeter, color: .white, isActive: true)
                    .transition(.opacity)
            } else {
                StaticVisualizer(color: .white)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: currentState)
    }
}

struct ProcessingStatusDisplay: View {
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text("Working")
                .foregroundColor(color)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.5)

            ProgressAnimation(color: color, animationSpeed: 0.18)
        }
        .frame(height: 28)
    }
}
