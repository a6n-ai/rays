import SwiftUI

/// What a model does, from its Hugging Face pipeline tag: one symbol, colour and label everywhere it appears.
enum ModelKind: CaseIterable {
    case text, vision, image, video, speech, voice, audio, embeddings, visionTasks, other

    init(pipelineTag tag: String?) {
        switch tag ?? "" {
        case "text-generation", "text2text-generation": self = .text
        case "image-text-to-text", "visual-question-answering", "image-to-text": self = .vision
        case "text-to-image", "image-to-image": self = .image
        case "text-to-video", "image-to-video": self = .video
        case "automatic-speech-recognition": self = .speech
        case "text-to-speech", "text-to-audio": self = .voice
        case "feature-extraction", "sentence-similarity": self = .embeddings
        case "image-classification", "object-detection", "image-segmentation", "depth-estimation": self = .visionTasks
        case let other where other.hasPrefix("audio-"): self = .audio
        default: self = .other
        }
    }

    var symbol: String {
        switch self {
        case .text: "text.bubble.fill"
        case .vision: "photo.on.rectangle.angled"
        case .image: "paintbrush.pointed.fill"
        case .video: "film.fill"
        case .speech: "waveform"
        case .voice: "speaker.wave.2.fill"
        case .audio: "waveform.circle.fill"
        case .embeddings: "point.3.connected.trianglepath.dotted"
        case .visionTasks: "eye.fill"
        case .other: "cube.fill"
        }
    }

    var color: Color {
        switch self {
        case .text: .blue
        case .vision: .purple
        case .image: .pink
        case .video: .orange
        case .speech: .green
        case .voice: .teal
        case .audio: .mint
        case .embeddings: .indigo
        case .visionTasks: .yellow
        case .other: .gray
        }
    }

    var label: String {
        switch self {
        case .text: "Text"
        case .vision: "Vision"
        case .image: "Image"
        case .video: "Video"
        case .speech: "Speech"
        case .voice: "Voice"
        case .audio: "Audio"
        case .embeddings: "Embeddings"
        case .visionTasks: "Vision tasks"
        case .other: "Model"
        }
    }
}

/// The filter chips above the model list; Audio groups the three sound kinds.
enum ModelFilter: CaseIterable {
    case all, text, vision, image, audio, embeddings

    var label: String { self == .all ? "All" : representative.label }

    var representative: ModelKind {
        switch self {
        case .all: .other
        case .text: .text
        case .vision: .vision
        case .image: .image
        case .audio: .audio
        case .embeddings: .embeddings
        }
    }

    var color: Color { self == .all ? .accentColor : representative.color }

    func matches(_ kind: ModelKind) -> Bool {
        switch self {
        case .all: true
        case .audio: [.speech, .voice, .audio].contains(kind)
        default: kind == representative
        }
    }
}

/// An app-icon-like square: gradient fill, white symbol.
struct ModelTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = LayoutMetrics.iconSize

    init(kind: ModelKind, size: CGFloat = LayoutMetrics.iconSize) {
        self.init(symbol: kind.symbol, color: kind.color, size: size)
    }

    init(symbol: String, color: Color, size: CGFloat = LayoutMetrics.iconSize) {
        self.symbol = symbol
        self.color = color
        self.size = size
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

/// A small label pill; tinted for a kind, neutral for facts like GGUF and Gated.
struct ModelCapsule: View {
    let text: String
    var tint: Color?

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint ?? .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.map { AnyShapeStyle($0.opacity(0.18)) } ?? AnyShapeStyle(.quaternary), in: .capsule)
    }
}
