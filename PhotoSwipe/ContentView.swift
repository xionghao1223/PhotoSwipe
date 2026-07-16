import Photos
import PhotosUI
import SwiftUI
import UIKit

private enum AppScreen {
  case detail
  case batchReview
}

private enum AppAlert: Identifiable {
  case confirmDelete(Int)
  case confirmBatchSize(Int)
  case confirmReset
  case message(title: String, body: String)

  var id: String {
    switch self {
    case .confirmDelete:
      return "confirm-delete"
    case .confirmBatchSize:
      return "confirm-batch-size"
    case .confirmReset:
      return "confirm-reset"
    case .message(let title, let body):
      return "message-\(title)-\(body)"
    }
  }
}

private struct SharePayload: Identifiable {
  let id = UUID()
  let fileURL: URL
}

private struct PhotoInfoPayload: Identifiable {
  let id: String
  let asset: PHAsset
  let isFavorite: Bool

  init(asset: PHAsset, isFavorite: Bool) {
    id = asset.localIdentifier
    self.asset = asset
    self.isFavorite = isFavorite
  }
}

private struct ToastPayload: Identifiable {
  let id = UUID()
  let message: String
}

private struct BottomBarHeightKey: PreferenceKey {
  static let defaultValue: CGFloat = 0

  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

struct ContentView: View {
  @StateObject private var manager = PhotoLibraryManager()
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  @State private var currentScreen: AppScreen = .detail
  @State private var offset: CGSize = .zero
  @State private var cardRotation = 0.0
  @State private var cardScale: CGFloat = 1
  @State private var cardKey = UUID()
  @State private var isTransitioning = false

  @State private var activeAlert: AppAlert?
  @State private var infoPayload: PhotoInfoPayload?
  @State private var sharePayload: SharePayload?
  @State private var isPreparingShare = false
  @State private var shareProgress = 0.0
  @State private var toast: ToastPayload?
  @State private var toastTask: Task<Void, Never>?
  @State private var bottomBarHeight: CGFloat = 0

  private let switchThreshold: CGFloat = 68

  var body: some View {
    ZStack {
      background

      stateContent
        .animation(.easeInOut(duration: reduceMotion ? 0 : 0.22), value: manager.viewState)

      if manager.isProcessingBatch {
        processingOverlay(
          title: "正在移到最近删除",
          detail: "请在系统提示中确认"
        )
      } else if isPreparingShare {
        processingOverlay(
          title: "正在准备原图",
          detail: shareProgress > 0 ? "\(Int(shareProgress * 100))%" : "正在读取照片"
        )
      }

      if let toast {
        toastView(toast)
      }
    }
    .onPreferenceChange(BottomBarHeightKey.self) { bottomBarHeight = $0 }
    .preferredColorScheme(.dark)
    .task { manager.prepare() }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active {
        manager.prepare()
      }
    }
    .onChange(of: manager.batchComplete) { _, isComplete in
      if isComplete {
        withAnimation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.86)) {
          currentScreen = .batchReview
        }
      } else if currentScreen == .batchReview && !manager.isProcessingBatch {
        currentScreen = .detail
      }
    }
    .onChange(of: manager.viewState) { _, state in
      if state != .ready {
        currentScreen = .detail
        resetCardPosition()
      }
    }
    .sheet(item: $sharePayload) { payload in
      ActivityView(activityItems: [payload.fileURL])
        .onDisappear {
          try? FileManager.default.removeItem(at: payload.fileURL)
        }
    }
    .sheet(item: $infoPayload) { payload in
      PhotoInfoSheet(asset: payload.asset, isFavorite: payload.isFavorite)
    }
    .alert(item: $activeAlert, content: alert(for:))
  }

  private var background: some View {
    ZStack {
      LinearGradient(
        colors: [PhotoSwipeTheme.backgroundTop, PhotoSwipeTheme.backgroundBottom],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )

      RadialGradient(
        colors: [PhotoSwipeTheme.accent.opacity(0.14), .clear],
        center: .topTrailing,
        startRadius: 0,
        endRadius: 420
      )
    }
    .ignoresSafeArea()
  }

  @ViewBuilder
  private var stateContent: some View {
    switch manager.viewState {
    case .needsPermission:
      permissionIntro
    case .requesting:
      loadingState(title: "等待照片权限", detail: "请在系统提示中选择允许访问")
    case .loading:
      loadingState(title: "正在准备照片", detail: "所有整理都只在这台设备上完成")
    case .ready:
      readyContent
    case .empty:
      emptyState
    case .denied:
      deniedState
    case .restricted:
      restrictedState
    case .completed:
      completedState
    case .failed(let message):
      failedState(message: message)
    }
  }

  @ViewBuilder
  private var readyContent: some View {
    switch currentScreen {
    case .detail:
      detailView
    case .batchReview:
      batchReviewView
    }
  }

  private var permissionIntro: some View {
    ScrollView {
      VStack(spacing: 30) {
        Spacer(minLength: 36)

        ZStack {
          RoundedRectangle(cornerRadius: 30, style: .continuous)
            .fill(
              LinearGradient(
                colors: [PhotoSwipeTheme.accent, PhotoSwipeTheme.accentStrong],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
              )
            )
            .frame(width: 116, height: 116)
            .shadow(color: PhotoSwipeTheme.accentStrong.opacity(0.34), radius: 28, y: 16)

          Image(systemName: "photo.on.rectangle.angled")
            .font(.system(size: 48, weight: .semibold))
            .foregroundStyle(.white)
        }

        VStack(spacing: 12) {
          Text("相册整理")
            .font(.subheadline.weight(.bold))
            .foregroundStyle(PhotoSwipeTheme.accent)
            .textCase(.uppercase)

          Text("留下真正重要的照片")
            .font(.largeTitle.bold())
            .multilineTextAlignment(.center)

          Text("轻扫浏览，先标记再确认。没有你的最后确认，任何照片都不会被删除。")
            .font(.body)
            .foregroundStyle(PhotoSwipeTheme.textSecondary)
            .multilineTextAlignment(.center)
            .lineSpacing(4)
        }

        VStack(spacing: 0) {
          PrivacyPromiseRow(
            icon: "lock.shield.fill",
            title: "只在设备上处理",
            detail: "照片不会上传到服务器"
          )
          Divider().overlay(PhotoSwipeTheme.hairline).padding(.leading, 60)
          PrivacyPromiseRow(
            icon: "checkmark.circle.fill",
            title: "先标记，再确认",
            detail: "误标可随时取消"
          )
          Divider().overlay(PhotoSwipeTheme.hairline).padding(.leading, 60)
          PrivacyPromiseRow(
            icon: "arrow.uturn.backward.circle.fill",
            title: "仍可从系统恢复",
            detail: "确认后只会移到“最近删除”"
          )
        }
        .background(
          PhotoSwipeTheme.surface,
          in: RoundedRectangle(cornerRadius: PhotoSwipeTheme.largeRadius, style: .continuous)
        )
        .overlay {
          RoundedRectangle(cornerRadius: PhotoSwipeTheme.largeRadius, style: .continuous)
            .stroke(PhotoSwipeTheme.hairline, lineWidth: 1)
        }

        Button(action: manager.requestAuthorization) {
          HStack(spacing: 10) {
            Text("开始整理")
            Image(systemName: "arrow.right")
          }
          .font(.headline)
          .foregroundStyle(.white)
          .frame(maxWidth: .infinity)
          .frame(height: 56)
          .background(
            LinearGradient(
              colors: [PhotoSwipeTheme.accent, PhotoSwipeTheme.accentStrong],
              startPoint: .leading,
              endPoint: .trailing
            ),
            in: Capsule()
          )
        }
        .buttonStyle(.plain)

        Text("你可以允许访问全部照片，也可以只选择一部分。")
          .font(.footnote)
          .foregroundStyle(PhotoSwipeTheme.textTertiary)
          .multilineTextAlignment(.center)
      }
      .frame(maxWidth: 520)
      .padding(.horizontal, 24)
      .padding(.bottom, 32)
      .frame(maxWidth: .infinity)
    }
  }

  private func loadingState(title: String, detail: String) -> some View {
    StateMessageView(
      icon: "photo.stack",
      title: title,
      detail: detail,
      tint: PhotoSwipeTheme.accent,
      showsProgress: true
    )
  }

  private var emptyState: some View {
    StateMessageView(
      icon: manager.authorizationStatus == .limited
        ? "photo.badge.plus" : "photo.on.rectangle.angled",
      title: manager.authorizationStatus == .limited ? "还没有可整理的照片" : "相册里还没有照片",
      detail: manager.authorizationStatus == .limited
        ? "你目前只允许了部分照片，可以继续添加可访问的照片。"
        : "拍几张照片后再回来，App 会自动为你准备第一批。",
      tint: PhotoSwipeTheme.accent
    ) {
      if manager.authorizationStatus == .limited {
        Button("管理可访问照片", action: presentLimitedLibraryPicker)
          .buttonStyle(.borderedProminent)
          .buttonBorderShape(.capsule)
      }
      Button("重新载入") { manager.reload(keepingCurrentBatch: false) }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
    }
  }

  private var deniedState: some View {
    StateMessageView(
      icon: "lock.slash",
      title: "照片权限已关闭",
      detail: "请在系统设置中允许访问照片，才能继续整理。",
      tint: PhotoSwipeTheme.delete
    ) {
      Button("打开系统设置", action: openSettings)
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
    }
  }

  private var restrictedState: some View {
    StateMessageView(
      icon: "exclamationmark.shield",
      title: "无法访问照片",
      detail: "这台设备的家长控制或管理策略限制了照片访问。",
      tint: PhotoSwipeTheme.warning
    )
  }

  private var completedState: some View {
    StateMessageView(
      icon: "checkmark.seal.fill",
      title: "这一轮整理完成",
      detail: manager.deletedCount > 0
        ? "已检查当前可访问的照片，并将 \(manager.deletedCount) 张移到最近删除。"
        : "已检查当前可访问的全部照片。以后新增的照片仍会自动出现。",
      tint: PhotoSwipeTheme.success
    ) {
      HStack(spacing: 12) {
        StatisticTile(value: "\(manager.reviewedCount)", label: "已检查")
        StatisticTile(value: "\(manager.deletedCount)", label: "最近删除")
      }

      Button("检查新增照片") {
        manager.reload(keepingCurrentBatch: false)
      }
      .buttonStyle(.borderedProminent)
      .buttonBorderShape(.capsule)

      Button("重新整理全部照片") {
        activeAlert = .confirmReset
      }
      .buttonStyle(.bordered)
      .buttonBorderShape(.capsule)

      if manager.authorizationStatus == .limited {
        Button("管理可访问照片", action: presentLimitedLibraryPicker)
          .buttonStyle(.bordered)
          .buttonBorderShape(.capsule)
      }
    }
  }

  private func failedState(message: String) -> some View {
    StateMessageView(
      icon: "exclamationmark.triangle",
      title: "照片载入失败",
      detail: message,
      tint: PhotoSwipeTheme.warning
    ) {
      Button("重试") { manager.reload(keepingCurrentBatch: true) }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
    }
  }

  private var detailView: some View {
    Group {
      if dynamicTypeSize.isAccessibilitySize {
        ScrollView {
          detailViewContents
        }
        .scrollIndicators(.hidden)
      } else {
        detailViewContents
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      decisionDock
        .background {
          GeometryReader { geometry in
            Color.clear.preference(key: BottomBarHeightKey.self, value: geometry.size.height)
          }
        }
    }
  }

  private var detailViewContents: some View {
    VStack(spacing: 14) {
      detailTopBar

      if manager.authorizationStatus == .limited {
        limitedAccessBanner
      }

      if let asset = manager.currentAsset {
        PhotoDetailCard(
          asset: asset,
          offset: offset,
          rotation: cardRotation,
          scale: cardScale,
          isMarkedForDeletion: manager.currentIsMarked
        )
        .overlay(alignment: .topTrailing) {
          favoriteButton
            .padding(14)
        }
        .overlay(alignment: .bottomLeading) {
          metadataButton
            .padding(14)
        }
        .id("\(asset.localIdentifier)-\(cardKey)")
        .frame(minHeight: dynamicTypeSize.isAccessibilitySize ? 360 : nil)
        .simultaneousGesture(dragGesture)
        .accessibilityAction(named: "上一张") { moveToPrevious() }
        .accessibilityAction(named: "下一张") { moveToNext() }
        .accessibilityAction(named: "切换待删除标记") { toggleMark() }
      }
    }
    .padding(.horizontal, 16)
    .padding(.top, 12)
    .padding(.bottom, 12)
  }

  private var detailTopBar: some View {
    VStack(spacing: 11) {
      HStack(spacing: 14) {
        VStack(alignment: .leading, spacing: 3) {
          Text("第 \(manager.currentIndex + 1) 张")
            .font(.title2.weight(.bold))
            .foregroundStyle(PhotoSwipeTheme.textPrimary)

          Text("本批共 \(manager.currentBatchAssets.count) 张 · 还剩 \(manager.remainingCount) 张")
            .font(.caption.weight(.medium))
            .foregroundStyle(PhotoSwipeTheme.textSecondary)
        }

        Spacer()

        Menu {
          Button(action: prepareShare) {
            Label("分享当前照片", systemImage: "square.and.arrow.up")
          }
          .disabled(isPreparingShare)

          Divider()

          Section("每批照片") {
            ForEach(manager.availableSizes, id: \.self) { size in
              Button {
                chooseBatchSize(size)
              } label: {
                if size == manager.batchSize {
                  Label("\(size) 张", systemImage: "checkmark")
                } else {
                  Text("\(size) 张")
                }
              }
            }
          }

          if manager.authorizationStatus == .limited {
            Divider()
            Button(action: presentLimitedLibraryPicker) {
              Label("管理可访问照片", systemImage: "photo.badge.plus")
            }
          }
        } label: {
          Image(systemName: "ellipsis")
            .font(.headline.weight(.bold))
            .foregroundStyle(PhotoSwipeTheme.textPrimary)
            .frame(width: 44, height: 44)
            .background(PhotoSwipeTheme.surfaceStrong, in: Circle())
            .overlay {
              Circle().stroke(PhotoSwipeTheme.hairline, lineWidth: 1)
            }
        }
        .accessibilityLabel("更多操作")
      }

      ProgressView(
        value: Double(manager.currentIndex + 1),
        total: Double(max(manager.currentBatchAssets.count, 1))
      )
      .tint(PhotoSwipeTheme.accent)
      .background(PhotoSwipeTheme.surfaceStrong)
      .clipShape(Capsule())
      .accessibilityLabel("本批进度")
      .accessibilityValue(manager.batchProgress)
    }
  }

  private var limitedAccessBanner: some View {
    Button(action: presentLimitedLibraryPicker) {
      HStack(spacing: 9) {
        Image(systemName: "photo.badge.exclamationmark")
          .foregroundStyle(PhotoSwipeTheme.accent)
        Text("当前仅整理已授权的照片")
          .font(.footnote.weight(.semibold))
        Spacer()
        Text("管理")
          .font(.footnote.weight(.bold))
          .foregroundStyle(PhotoSwipeTheme.accent)
        Image(systemName: "chevron.right")
          .font(.caption.bold())
          .foregroundStyle(PhotoSwipeTheme.accent)
      }
      .foregroundStyle(PhotoSwipeTheme.textSecondary)
      .padding(.horizontal, 14)
      .frame(minHeight: 44)
      .background(
        PhotoSwipeTheme.accent.opacity(0.1),
        in: RoundedRectangle(cornerRadius: PhotoSwipeTheme.smallRadius, style: .continuous)
      )
    }
    .accessibilityHint("选择更多允许本 App 访问的照片")
  }

  private var metadataButton: some View {
    Button {
      if let asset = manager.currentAsset {
        infoPayload = PhotoInfoPayload(asset: asset, isFavorite: manager.currentIsFavorite)
      }
    } label: {
      HStack(spacing: 8) {
        Image(systemName: "calendar")
        Text(currentPhotoDateText)
          .lineLimit(1)
        Image(systemName: "info.circle")
          .foregroundStyle(PhotoSwipeTheme.textSecondary)
      }
      .font(.caption.weight(.semibold))
      .foregroundStyle(.white)
      .padding(.horizontal, 12)
      .frame(minHeight: 38)
      .background(.ultraThinMaterial, in: Capsule())
      .overlay {
        Capsule().stroke(PhotoSwipeTheme.hairline, lineWidth: 1)
      }
    }
    .accessibilityLabel("照片信息，\(currentPhotoDateText)")
  }

  private var favoriteButton: some View {
    Button(action: toggleFavorite) {
      Image(systemName: manager.currentIsFavorite ? "heart.fill" : "heart")
        .font(.headline.weight(.bold))
        .foregroundStyle(
          manager.currentIsFavorite ? PhotoSwipeTheme.favorite : PhotoSwipeTheme.textPrimary
        )
        .frame(width: 44, height: 44)
        .background(.ultraThinMaterial, in: Circle())
        .overlay {
          Circle().stroke(PhotoSwipeTheme.hairline, lineWidth: 1)
        }
    }
    .disabled(manager.isUpdatingFavorite || isTransitioning)
    .accessibilityLabel(manager.currentIsFavorite ? "取消收藏" : "收藏")
  }

  private var decisionDock: some View {
    VStack(spacing: 10) {
      if dynamicTypeSize.isAccessibilitySize {
        previousWideButton
        deleteDecisionButton
        nextDecisionButton
      } else {
        HStack(spacing: 10) {
          previousCompactButton
          deleteDecisionButton
          nextDecisionButton
        }
      }

      Text(
        manager.isLastPhoto
          ? "完成最后一张后进入整批确认"
          : "也可以左右滑动切换照片"
      )
      .font(.caption2.weight(.medium))
      .foregroundStyle(PhotoSwipeTheme.textTertiary)
    }
    .padding(.horizontal, 16)
    .padding(.top, 13)
    .padding(.bottom, 8)
    .background(.ultraThinMaterial)
    .overlay(alignment: .top) {
      Divider().overlay(PhotoSwipeTheme.hairline)
    }
  }

  private var previousCompactButton: some View {
    Button(action: moveToPrevious) {
      Image(systemName: "chevron.left")
        .font(.headline.weight(.bold))
        .foregroundStyle(PhotoSwipeTheme.textPrimary)
        .frame(width: 52, height: 52)
        .background(PhotoSwipeTheme.surfaceStrong, in: Circle())
        .overlay { Circle().stroke(PhotoSwipeTheme.hairline, lineWidth: 1) }
    }
    .disabled(manager.isFirstPhoto || isTransitioning)
    .opacity(manager.isFirstPhoto ? 0.38 : 1)
    .accessibilityLabel("上一张")
  }

  private var previousWideButton: some View {
    Button(action: moveToPrevious) {
      Label("上一张", systemImage: "chevron.left")
        .font(.headline)
        .foregroundStyle(PhotoSwipeTheme.textPrimary)
        .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 10 : 0)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 52)
        .background(PhotoSwipeTheme.surfaceStrong, in: Capsule())
        .overlay { Capsule().stroke(PhotoSwipeTheme.hairline, lineWidth: 1) }
    }
    .disabled(manager.isFirstPhoto || isTransitioning)
    .opacity(manager.isFirstPhoto ? 0.38 : 1)
  }

  private var deleteDecisionButton: some View {
    Button(action: toggleMark) {
      Label(
        manager.currentIsMarked ? "取消标记" : "标记删除",
        systemImage: manager.currentIsMarked ? "trash.slash.fill" : "trash"
      )
      .font(.subheadline.weight(.bold))
      .foregroundStyle(
        manager.currentIsMarked ? .white : PhotoSwipeTheme.delete
      )
      .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 10 : 0)
      .frame(maxWidth: .infinity)
      .frame(minHeight: 52)
      .background(
        manager.currentIsMarked
          ? PhotoSwipeTheme.delete.opacity(0.88)
          : PhotoSwipeTheme.delete.opacity(0.08),
        in: Capsule()
      )
      .overlay {
        Capsule().stroke(PhotoSwipeTheme.delete.opacity(0.8), lineWidth: 1.5)
      }
    }
    .disabled(isTransitioning)
  }

  private var nextDecisionButton: some View {
    Button(action: moveToNext) {
      Label(
        manager.isLastPhoto
          ? "审核本批"
          : (manager.currentIsMarked
            ? "下一张"
            : (dynamicTypeSize.isAccessibilitySize ? "保留并下一张" : "保留")),
        systemImage: manager.isLastPhoto ? "checkmark" : "arrow.right"
      )
      .font(.subheadline.weight(.bold))
      .foregroundStyle(.white)
      .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 10 : 0)
      .frame(maxWidth: .infinity)
      .frame(minHeight: 52)
      .background(
        LinearGradient(
          colors: [PhotoSwipeTheme.accent, PhotoSwipeTheme.accentStrong],
          startPoint: .leading,
          endPoint: .trailing
        ),
        in: Capsule()
      )
      .shadow(color: PhotoSwipeTheme.accentStrong.opacity(0.26), radius: 14, y: 7)
    }
    .disabled(isTransitioning)
    .accessibilityLabel(
      manager.isLastPhoto
        ? "审核本批"
        : (manager.currentIsMarked ? "下一张" : "保留并下一张")
    )
  }

  private var batchReviewView: some View {
    ScrollView {
      VStack(spacing: 20) {
        reviewHeader

        LazyVGrid(
          columns: reviewColumns,
          spacing: 8
        ) {
          ForEach(
            Array(manager.currentBatchAssets.enumerated()),
            id: \.element.localIdentifier
          ) { item in
            let index = item.offset
            let asset = item.element
            Button {
              manager.toggleMark(for: asset)
              UISelectionFeedbackGenerator().selectionChanged()
            } label: {
              PhotoThumbnail(asset: asset, isMarked: manager.isMarked(asset))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(reviewThumbnailLabel(asset: asset, index: index))
            .accessibilityValue(manager.isMarked(asset) ? "待移到最近删除" : "保留")
            .accessibilityHint("双击切换这张照片的标记")
          }
        }
        .frame(maxWidth: 620)

        Text("点按任意缩略图可更改选择。提交后，照片会进入系统“最近删除”，仍可在那里恢复。")
          .font(.footnote)
          .foregroundStyle(PhotoSwipeTheme.textSecondary)
          .multilineTextAlignment(.center)
          .lineSpacing(3)
          .frame(maxWidth: 520)
          .padding(.vertical, 8)
      }
      .padding(.horizontal, 16)
      .padding(.top, 12)
      .padding(.bottom, 16)
    }
    .safeAreaInset(edge: .bottom) {
      reviewActions
        .background {
          GeometryReader { geometry in
            Color.clear.preference(key: BottomBarHeightKey.self, value: geometry.size.height)
          }
        }
    }
    .disabled(manager.isProcessingBatch)
  }

  private var reviewColumns: [GridItem] {
    if dynamicTypeSize.isAccessibilitySize {
      return Array(repeating: GridItem(.flexible(), spacing: 8), count: 2)
    }
    return [GridItem(.adaptive(minimum: 104, maximum: 168), spacing: 8)]
  }

  private var reviewHeader: some View {
    VStack(alignment: .leading, spacing: 18) {
      Button(action: returnToCurrentBatch) {
        Label("返回继续检查", systemImage: "chevron.left")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(PhotoSwipeTheme.textSecondary)
          .frame(minHeight: 44)
      }

      VStack(alignment: .leading, spacing: 6) {
        Text("确认这一批")
          .font(.largeTitle.bold())
          .foregroundStyle(PhotoSwipeTheme.textPrimary)
        Text("最后检查一次，点按照片即可更改标记")
          .font(.subheadline)
          .foregroundStyle(PhotoSwipeTheme.textSecondary)
      }

      HStack(spacing: 0) {
        reviewStatistic(
          value: manager.currentBatchAssets.count,
          label: "已检查",
          tint: PhotoSwipeTheme.accent
        )

        Divider()
          .overlay(PhotoSwipeTheme.hairline)
          .frame(height: 48)

        reviewStatistic(
          value: manager.markedCount,
          label: "待删除",
          tint: manager.markedCount > 0 ? PhotoSwipeTheme.delete : PhotoSwipeTheme.textSecondary
        )
      }
      .padding(.vertical, 16)
      .background(
        PhotoSwipeTheme.surface,
        in: RoundedRectangle(cornerRadius: PhotoSwipeTheme.mediumRadius, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: PhotoSwipeTheme.mediumRadius, style: .continuous)
          .stroke(PhotoSwipeTheme.hairline, lineWidth: 1)
      }
    }
  }

  private func reviewStatistic(value: Int, label: String, tint: Color) -> some View {
    VStack(spacing: 3) {
      Text("\(value)")
        .font(.title2.bold().monospacedDigit())
        .foregroundStyle(tint)
      Text(label)
        .font(.caption.weight(.semibold))
        .foregroundStyle(PhotoSwipeTheme.textSecondary)
    }
    .frame(maxWidth: .infinity)
  }

  private var reviewActions: some View {
    VStack(spacing: 10) {
      if manager.markedCount > 0 {
        Button {
          activeAlert = .confirmDelete(manager.markedCount)
        } label: {
          Label("将 \(manager.markedCount) 张移到最近删除", systemImage: "trash.fill")
            .font(.headline)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 54)
        }
        .foregroundStyle(.white)
        .background(PhotoSwipeTheme.delete.opacity(0.9), in: Capsule())
        .shadow(color: PhotoSwipeTheme.delete.opacity(0.2), radius: 14, y: 7)

        Button(action: keepCurrentBatch) {
          Text("清除标记并全部保留")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(PhotoSwipeTheme.textSecondary)
            .frame(minHeight: 44)
        }
      } else {
        Button(action: keepCurrentBatch) {
          Label("全部保留，继续下一批", systemImage: "arrow.right")
            .font(.headline)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 54)
            .background(
              LinearGradient(
                colors: [PhotoSwipeTheme.accent, PhotoSwipeTheme.accentStrong],
                startPoint: .leading,
                endPoint: .trailing
              ),
              in: Capsule()
            )
        }
      }
    }
    .padding(.horizontal, 16)
    .padding(.top, 13)
    .padding(.bottom, 8)
    .background(.ultraThinMaterial)
    .overlay(alignment: .top) {
      Divider().overlay(PhotoSwipeTheme.hairline)
    }
  }

  private var dragGesture: some Gesture {
    DragGesture(minimumDistance: 12)
      .onChanged { value in
        guard !isTransitioning else { return }
        let horizontal = abs(value.translation.width)
        let vertical = abs(value.translation.height)
        guard horizontal > vertical else { return }

        offset = CGSize(width: value.translation.width, height: value.translation.height * 0.08)
        let width = max(UIScreen.main.bounds.width, 1)
        cardRotation = Double(value.translation.width / width) * 7
        cardScale = min(1.025, 1 + horizontal / width * 0.018)
      }
      .onEnded { value in
        guard !isTransitioning else { return }
        let predicted = value.predictedEndTranslation
        let horizontal = abs(predicted.width)
        let vertical = abs(predicted.height)
        guard horizontal > vertical * 1.15, horizontal > switchThreshold else {
          snapBack()
          return
        }

        if predicted.width < 0 {
          moveToNext()
        } else {
          moveToPrevious()
        }
      }
  }

  private func moveToNext() {
    guard !isTransitioning else { return }
    UIImpactFeedbackGenerator(style: .light).impactOccurred()

    if manager.isLastPhoto {
      manager.goNext()
      snapBack()
      return
    }

    guard !reduceMotion else {
      manager.goNext()
      cardKey = UUID()
      resetCardPosition()
      return
    }

    isTransitioning = true
    withAnimation(.easeOut(duration: 0.2)) {
      offset = CGSize(width: -UIScreen.main.bounds.width * 1.15, height: 0)
      cardScale = 0.94
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
      manager.goNext()
      resetCardPosition()
      cardKey = UUID()
      isTransitioning = false
    }
  }

  private func moveToPrevious() {
    guard !isTransitioning, !manager.isFirstPhoto else {
      snapBack()
      return
    }
    UIImpactFeedbackGenerator(style: .light).impactOccurred()

    guard !reduceMotion else {
      manager.goPrevious()
      cardKey = UUID()
      resetCardPosition()
      return
    }

    isTransitioning = true
    withAnimation(.easeOut(duration: 0.2)) {
      offset = CGSize(width: UIScreen.main.bounds.width * 1.15, height: 0)
      cardScale = 0.94
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
      manager.goPrevious()
      resetCardPosition()
      cardKey = UUID()
      isTransitioning = false
    }
  }

  private func snapBack() {
    withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.78)) {
      resetCardPosition()
    }
  }

  private func resetCardPosition() {
    offset = .zero
    cardRotation = 0
    cardScale = 1
  }

  private func toggleMark() {
    manager.toggleMarkCurrent()
    UINotificationFeedbackGenerator().notificationOccurred(
      manager.currentIsMarked ? .warning : .success
    )
    showToast(manager.currentIsMarked ? "已标记，稍后统一确认" : "已取消待删除标记")
  }

  private func toggleFavorite() {
    manager.toggleFavoriteCurrent { result in
      switch result {
      case .success(let isFavorite):
        showToast(isFavorite ? "已加入收藏" : "已取消收藏")
      case .failure(let error):
        activeAlert = .message(title: "收藏失败", body: error.localizedDescription)
      }
    }
  }

  private func chooseBatchSize(_ size: Int) {
    guard size != manager.batchSize else { return }
    if manager.markedCount > 0 {
      activeAlert = .confirmBatchSize(size)
    } else {
      manager.setBatchSize(size)
      cardKey = UUID()
      showToast("已改为每批 \(size) 张")
    }
  }

  private func returnToCurrentBatch() {
    manager.resumeCurrentBatch()
    withAnimation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.88)) {
      currentScreen = .detail
    }
  }

  private func keepCurrentBatch() {
    let discardedMarks = manager.markedCount
    manager.keepCurrentBatch()
    currentScreen = .detail
    cardKey = UUID()
    showToast(discardedMarks > 0 ? "已放弃标记，本批全部保留" : "本批已保留")
  }

  private func executeDelete() {
    manager.executeBatchDelete { result in
      switch result {
      case .success(let count):
        currentScreen = .detail
        cardKey = UUID()
        showToast("已将 \(count) 张移到最近删除，可在系统照片中恢复", duration: 4.5)
      case .failure(let error):
        activeAlert = .message(
          title: "没有移动照片",
          body: "\(error.localizedDescription)\n\n当前选择仍然保留。"
        )
      }
    }
  }

  private func prepareShare() {
    guard let asset = manager.currentAsset, !isPreparingShare else { return }
    let resources = PHAssetResource.assetResources(for: asset)
    guard
      let resource = resources.first(where: { $0.type == .fullSizePhoto })
        ?? resources.first(where: { $0.type == .photo })
        ?? resources.first
    else {
      activeAlert = .message(title: "无法分享", body: "找不到这张照片的原始文件。")
      return
    }

    isPreparingShare = true
    shareProgress = 0
    let fileExtension = (resource.originalFilename as NSString).pathExtension
    let safeExtension = fileExtension.isEmpty ? "jpg" : fileExtension
    let destination = FileManager.default.temporaryDirectory
      .appendingPathComponent("PhotoSwipe-\(UUID().uuidString)")
      .appendingPathExtension(safeExtension)

    let options = PHAssetResourceRequestOptions()
    options.isNetworkAccessAllowed = true
    options.progressHandler = { progress in
      DispatchQueue.main.async {
        shareProgress = progress
      }
    }

    PHAssetResourceManager.default().writeData(
      for: resource,
      toFile: destination,
      options: options
    ) { error in
      DispatchQueue.main.async {
        isPreparingShare = false
        if let error {
          try? FileManager.default.removeItem(at: destination)
          activeAlert = .message(title: "无法分享", body: error.localizedDescription)
        } else {
          sharePayload = SharePayload(fileURL: destination)
        }
      }
    }
  }

  private func showToast(_ message: String, duration: Double = 2.8) {
    toastTask?.cancel()
    let payload = ToastPayload(message: message)
    withAnimation(.easeInOut(duration: reduceMotion ? 0 : 0.18)) {
      toast = payload
    }
    UIAccessibility.post(notification: .announcement, argument: message)

    toastTask = Task {
      try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
      guard !Task.isCancelled else { return }
      withAnimation(.easeInOut(duration: reduceMotion ? 0 : 0.2)) {
        if toast?.id == payload.id {
          toast = nil
        }
      }
    }
  }

  private func toastView(_ payload: ToastPayload) -> some View {
    VStack {
      Spacer()
      Text(payload.message)
        .font(.subheadline.weight(.semibold))
        .multilineTextAlignment(.center)
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay { Capsule().stroke(PhotoSwipeTheme.hairline, lineWidth: 1) }
        .padding(.horizontal, 28)
        .padding(.bottom, max(bottomBarHeight + 12, 24))
    }
    .transition(.opacity.combined(with: .move(edge: .bottom)))
    .zIndex(300)
    .allowsHitTesting(false)
  }

  private func processingOverlay(title: String, detail: String) -> some View {
    ZStack {
      Color.black.opacity(0.62).ignoresSafeArea()
      VStack(spacing: 14) {
        ProgressView()
          .tint(PhotoSwipeTheme.accent)
          .scaleEffect(1.25)
        Text(title)
          .font(.headline)
        Text(detail)
          .font(.subheadline)
          .foregroundStyle(PhotoSwipeTheme.textSecondary)
      }
      .padding(.horizontal, 34)
      .padding(.vertical, 28)
      .background(
        .ultraThinMaterial,
        in: RoundedRectangle(cornerRadius: PhotoSwipeTheme.largeRadius, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: PhotoSwipeTheme.largeRadius, style: .continuous)
          .stroke(PhotoSwipeTheme.hairline, lineWidth: 1)
      }
    }
    .zIndex(250)
  }

  private func alert(for item: AppAlert) -> Alert {
    switch item {
    case .confirmDelete(let count):
      return Alert(
        title: Text("移到最近删除？"),
        message: Text("将把 \(count) 张照片移到系统“最近删除”。系统还会再请你确认一次。"),
        primaryButton: .destructive(Text("继续"), action: executeDelete),
        secondaryButton: .cancel(Text("取消"))
      )
    case .confirmBatchSize(let size):
      return Alert(
        title: Text("改为每批 \(size) 张？"),
        message: Text("超出新批次范围的删除标记会取消，照片不会被删除。"),
        primaryButton: .default(Text("更改")) {
          manager.setBatchSize(size)
          cardKey = UUID()
          showToast("已改为每批 \(size) 张")
        },
        secondaryButton: .cancel(Text("取消"))
      )
    case .confirmReset:
      return Alert(
        title: Text("重新整理全部照片？"),
        message: Text("只会清除本机的已检查记录，不会更改或删除任何照片。"),
        primaryButton: .destructive(Text("重新开始")) {
          manager.resetProgress()
          currentScreen = .detail
          cardKey = UUID()
        },
        secondaryButton: .cancel(Text("取消"))
      )
    case .message(let title, let body):
      return Alert(title: Text(title), message: Text(body), dismissButton: .default(Text("好")))
    }
  }

  private var currentPhotoDateText: String {
    guard let date = manager.currentAsset?.creationDate else { return "拍摄日期未知" }
    return date.formatted(date: .abbreviated, time: .shortened)
  }

  private func openSettings() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    UIApplication.shared.open(url)
  }

  private func presentLimitedLibraryPicker() {
    guard let viewController = UIApplication.shared.topViewController else { return }
    PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: viewController) { _ in
      Task { @MainActor in
        manager.reload(keepingCurrentBatch: true)
      }
    }
  }

  private func reviewThumbnailLabel(asset: PHAsset, index: Int) -> String {
    let date = asset.creationDate?.formatted(date: .abbreviated, time: .omitted) ?? "日期未知"
    return "第 \(index + 1) 张，\(date)"
  }
}

private struct PrivacyPromiseRow: View {
  let icon: String
  let title: String
  let detail: String

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: icon)
        .font(.title3.weight(.semibold))
        .foregroundStyle(PhotoSwipeTheme.accent)
        .frame(width: 34, height: 34)
        .background(PhotoSwipeTheme.accent.opacity(0.13), in: Circle())

      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.headline)
        Text(detail)
          .font(.subheadline)
          .foregroundStyle(PhotoSwipeTheme.textSecondary)
      }
      Spacer()
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
  }
}

private struct StatisticTile: View {
  let value: String
  let label: String

  var body: some View {
    VStack(spacing: 4) {
      Text(value)
        .font(.title2.bold().monospacedDigit())
        .foregroundStyle(PhotoSwipeTheme.textPrimary)
      Text(label)
        .font(.caption.weight(.semibold))
        .foregroundStyle(PhotoSwipeTheme.textSecondary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 15)
    .background(
      PhotoSwipeTheme.surface,
      in: RoundedRectangle(cornerRadius: PhotoSwipeTheme.mediumRadius, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: PhotoSwipeTheme.mediumRadius, style: .continuous)
        .stroke(PhotoSwipeTheme.hairline, lineWidth: 1)
    }
  }
}

private struct StateMessageView<Actions: View>: View {
  let icon: String
  let title: String
  let detail: String
  let tint: Color
  let showsProgress: Bool
  @ViewBuilder let actions: Actions

  init(
    icon: String,
    title: String,
    detail: String,
    tint: Color = PhotoSwipeTheme.accent,
    showsProgress: Bool = false,
    @ViewBuilder actions: () -> Actions
  ) {
    self.icon = icon
    self.title = title
    self.detail = detail
    self.tint = tint
    self.showsProgress = showsProgress
    self.actions = actions()
  }

  var body: some View {
    GeometryReader { proxy in
      ScrollView {
        VStack(spacing: 22) {
          if showsProgress {
            ProgressView()
              .tint(tint)
              .scaleEffect(1.35)
              .frame(width: 88, height: 88)
              .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 24))
          } else {
            Image(systemName: icon)
              .font(.system(size: 42, weight: .semibold))
              .foregroundStyle(tint)
              .frame(width: 88, height: 88)
              .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 24))
          }

          VStack(spacing: 9) {
            Text(title)
              .font(.title2.bold())
              .foregroundStyle(PhotoSwipeTheme.textPrimary)
              .multilineTextAlignment(.center)
            Text(detail)
              .font(.body)
              .foregroundStyle(PhotoSwipeTheme.textSecondary)
              .multilineTextAlignment(.center)
              .lineSpacing(4)
          }

          VStack(spacing: 12) {
            actions
          }
        }
        .frame(maxWidth: 460)
        .padding(.horizontal, 32)
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity, minHeight: proxy.size.height)
      }
      .scrollIndicators(.hidden)
    }
    .tint(tint)
  }
}

extension StateMessageView where Actions == EmptyView {
  fileprivate init(
    icon: String,
    title: String,
    detail: String,
    tint: Color = PhotoSwipeTheme.accent,
    showsProgress: Bool = false
  ) {
    self.init(
      icon: icon,
      title: title,
      detail: detail,
      tint: tint,
      showsProgress: showsProgress,
      actions: { EmptyView() }
    )
  }
}

private struct ActivityView: UIViewControllerRepresentable {
  let activityItems: [Any]

  func makeUIViewController(context: Context) -> UIActivityViewController {
    UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
  }

  func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct PhotoInfoSheet: View {
  let asset: PHAsset
  let isFavorite: Bool
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        Section("拍摄信息") {
          InfoRow(title: "日期", value: dateText)
          InfoRow(title: "尺寸", value: "\(asset.pixelWidth) × \(asset.pixelHeight)")
          InfoRow(title: "类型", value: typeText)
        }

        Section {
          Label(
            isFavorite ? "已加入系统收藏" : "未加入系统收藏",
            systemImage: isFavorite ? "heart.fill" : "heart"
          )
        }
      }
      .navigationTitle("照片信息")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("完成", action: dismiss.callAsFunction)
        }
      }
    }
    .presentationDetents([.medium])
  }

  private var dateText: String {
    asset.creationDate?.formatted(date: .long, time: .shortened) ?? "未知"
  }

  private var typeText: String {
    if asset.mediaSubtypes.contains(.photoScreenshot) { return "截屏" }
    if asset.mediaSubtypes.contains(.photoPanorama) { return "全景照片" }
    if asset.mediaSubtypes.contains(.photoLive) { return "实况照片" }
    if asset.mediaSubtypes.contains(.photoHDR) { return "HDR 照片" }
    return "照片"
  }
}

private struct InfoRow: View {
  let title: String
  let value: String

  var body: some View {
    HStack {
      Text(title)
      Spacer()
      Text(value)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.trailing)
    }
  }
}

extension UIApplication {
  fileprivate var topViewController: UIViewController? {
    let activeScene =
      connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive }
    guard let root = activeScene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
    else {
      return nil
    }

    var current = root
    while let presented = current.presentedViewController {
      current = presented
    }
    if let navigationController = current as? UINavigationController {
      return navigationController.visibleViewController
    }
    if let tabBarController = current as? UITabBarController {
      return tabBarController.selectedViewController
    }
    return current
  }
}

#Preview {
  ContentView()
}
