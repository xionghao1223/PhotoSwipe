import Photos
import SwiftUI
import UIKit

struct PhotoDetailCard: View {
  let asset: PHAsset
  let offset: CGSize
  let rotation: Double
  let scale: CGFloat
  let isMarkedForDeletion: Bool

  @Environment(\.displayScale) private var displayScale
  @State private var image: UIImage?
  @State private var requestID: PHImageRequestID?
  @State private var progress: Double = 0
  @State private var loadError: String?

  var body: some View {
    GeometryReader { proxy in
      ZStack {
        RoundedRectangle(cornerRadius: PhotoSwipeTheme.largeRadius, style: .continuous)
          .fill(Color.black.opacity(0.32))
          .shadow(color: .black.opacity(0.42), radius: 28, x: 0, y: 18)

        if let image {
          Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        } else if let loadError {
          loadFailureView(message: loadError) {
            loadImage(for: proxy.size)
          }
        } else {
          loadingView
        }

        LinearGradient(
          colors: [.black.opacity(0.08), .clear, .black.opacity(0.2)],
          startPoint: .top,
          endPoint: .bottom
        )
        .allowsHitTesting(false)

        if isMarkedForDeletion {
          VStack {
            HStack {
              Label("待删除", systemImage: "trash.fill")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 13)
                .frame(minHeight: 38)
                .background(
                  PhotoSwipeTheme.delete.opacity(0.9),
                  in: Capsule()
                )
                .shadow(color: .black.opacity(0.24), radius: 10, y: 4)
              Spacer()
            }
            Spacer()
          }
          .padding(14)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: PhotoSwipeTheme.largeRadius, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: PhotoSwipeTheme.largeRadius, style: .continuous)
          .stroke(
            isMarkedForDeletion ? PhotoSwipeTheme.delete : PhotoSwipeTheme.hairline,
            lineWidth: isMarkedForDeletion ? 3 : 1
          )
      }
      .onAppear { loadImage(for: proxy.size) }
      .onChange(of: asset.localIdentifier) { _, _ in
        loadImage(for: proxy.size)
      }
      .onDisappear(perform: cancelRequest)
    }
    .offset(offset)
    .scaleEffect(scale)
    .rotationEffect(.degrees(rotation))
    .accessibilityElement(children: loadError == nil ? .ignore : .contain)
    .accessibilityLabel(loadError == nil ? "当前照片" : "照片载入失败")
    .accessibilityValue(
      loadError ?? (isMarkedForDeletion ? "已标记，提交后会移到最近删除" : "保留")
    )
  }

  private var loadingView: some View {
    VStack(spacing: 12) {
      ProgressView(value: progress > 0 ? progress : nil)
        .progressViewStyle(.circular)
        .tint(.white.opacity(0.8))
        .scaleEffect(1.15)

      Text(progress > 0 && progress < 1 ? "正在从 iCloud 下载 \(Int(progress * 100))%" : "正在载入照片")
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.white.opacity(0.72))
    }
  }

  private func loadFailureView(message: String, retry: @escaping () -> Void) -> some View {
    VStack(spacing: 14) {
      Image(systemName: "icloud.slash")
        .font(.system(size: 32, weight: .medium))
      Text(message)
        .font(.subheadline)
        .multilineTextAlignment(.center)
      Button("重新载入", action: retry)
        .buttonStyle(.borderedProminent)
    }
    .foregroundStyle(.white.opacity(0.86))
    .padding(24)
  }

  private func loadImage(for viewSize: CGSize) {
    cancelRequest()
    image = nil
    progress = 0
    loadError = nil

    let requestedIdentifier = asset.localIdentifier
    let options = PHImageRequestOptions()
    options.deliveryMode = .opportunistic
    options.resizeMode = .fast
    options.isNetworkAccessAllowed = true
    options.isSynchronous = false
    options.progressHandler = { value, error, _, _ in
      DispatchQueue.main.async {
        guard requestedIdentifier == asset.localIdentifier else { return }
        progress = value
        if let error {
          loadError = error.localizedDescription
        }
      }
    }

    let width = max(viewSize.width, 320) * displayScale
    let height = max(viewSize.height, 480) * displayScale
    requestID = PHImageManager.default().requestImage(
      for: asset,
      targetSize: CGSize(width: width, height: height),
      contentMode: .aspectFit,
      options: options
    ) { result, info in
      let cancelled = info?[PHImageCancelledKey] as? Bool ?? false
      let error = info?[PHImageErrorKey] as? Error
      let isDegraded = info?[PHImageResultIsDegradedKey] as? Bool ?? false
      DispatchQueue.main.async {
        guard !cancelled, requestedIdentifier == asset.localIdentifier else { return }
        if let result {
          image = result
          loadError = nil
        } else if let error {
          loadError = error.localizedDescription
        } else if !isDegraded {
          loadError = "照片暂时无法载入"
        }
      }
    }
  }

  private func cancelRequest() {
    if let requestID {
      PHImageManager.default().cancelImageRequest(requestID)
    }
    requestID = nil
  }
}

struct PhotoThumbnail: View {
  let asset: PHAsset
  let isMarked: Bool

  @Environment(\.displayScale) private var displayScale
  @State private var image: UIImage?
  @State private var requestID: PHImageRequestID?
  @State private var failed = false
  @State private var loadedIdentifier: String?

  var body: some View {
    ZStack(alignment: .topTrailing) {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(PhotoSwipeTheme.surface)

      Group {
        if let image {
          Image(uiImage: image)
            .resizable()
            .scaledToFill()
        } else if failed {
          Image(systemName: "photo.badge.exclamationmark")
            .font(.title2)
            .foregroundStyle(.white.opacity(0.55))
        } else {
          ProgressView()
            .tint(.white.opacity(0.6))
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .clipped()

      if isMarked {
        Color.black.opacity(0.24)

        Image(systemName: "trash.fill")
          .font(.caption.weight(.bold))
          .foregroundStyle(.white)
          .frame(width: 30, height: 30)
          .background(PhotoSwipeTheme.delete, in: Circle())
          .padding(7)
          .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
      }
    }
    .aspectRatio(1, contentMode: .fit)
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(
          isMarked ? PhotoSwipeTheme.delete : PhotoSwipeTheme.hairline,
          lineWidth: isMarked ? 3 : 1
        )
    }
    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .onAppear(perform: loadImage)
    .onChange(of: asset.localIdentifier) { _, _ in loadImage() }
    .onDisappear(perform: cancelRequest)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("照片")
    .accessibilityValue(isMarked ? "待移到最近删除" : "保留")
  }

  private func loadImage() {
    guard image == nil || loadedIdentifier != asset.localIdentifier else { return }
    cancelRequest()
    image = nil
    failed = false

    let requestedIdentifier = asset.localIdentifier
    let options = PHImageRequestOptions()
    options.deliveryMode = .opportunistic
    options.resizeMode = .fast
    options.isNetworkAccessAllowed = true
    options.isSynchronous = false

    let side = 180 * displayScale
    requestID = PHImageManager.default().requestImage(
      for: asset,
      targetSize: CGSize(width: side, height: side),
      contentMode: .aspectFill,
      options: options
    ) { result, info in
      let cancelled = info?[PHImageCancelledKey] as? Bool ?? false
      let error = info?[PHImageErrorKey] as? Error
      let isDegraded = info?[PHImageResultIsDegradedKey] as? Bool ?? false
      DispatchQueue.main.async {
        guard !cancelled, requestedIdentifier == asset.localIdentifier else { return }
        if let result {
          image = result
          loadedIdentifier = requestedIdentifier
          failed = false
        } else if error != nil || !isDegraded {
          failed = true
        }
      }
    }
  }

  private func cancelRequest() {
    if let requestID {
      PHImageManager.default().cancelImageRequest(requestID)
    }
    requestID = nil
  }
}
