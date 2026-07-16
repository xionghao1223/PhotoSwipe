import Combine
import Foundation
import Photos

enum LibraryViewState: Equatable {
  case needsPermission
  case requesting
  case loading
  case ready
  case empty
  case denied
  case restricted
  case completed
  case failed(String)
}

enum PhotoLibraryManagerError: LocalizedError {
  case operationInProgress
  case batchNotReady
  case noPhotosSelected
  case deletionFailed
  case favoriteUpdateFailed

  var errorDescription: String? {
    switch self {
    case .operationInProgress:
      return "已有操作正在进行，请稍候"
    case .batchNotReady:
      return "请先完成当前批次的检查"
    case .noPhotosSelected:
      return "还没有选择要移到最近删除的照片"
    case .deletionFailed:
      return "没有移动任何照片。你的选择已保留，可以重试"
    case .favoriteUpdateFailed:
      return "收藏状态更新失败，请稍后重试"
    }
  }
}

@MainActor
final class PhotoLibraryManager: ObservableObject {
  @Published private(set) var viewState: LibraryViewState
  @Published private(set) var authorizationStatus: PHAuthorizationStatus
  @Published private(set) var assets: [PHAsset] = []
  @Published private(set) var currentBatchAssets: [PHAsset] = []
  @Published private(set) var currentIndex = 0
  @Published private(set) var markedAssetIdentifiers: Set<String> = []
  @Published private(set) var batchSize: Int
  @Published private(set) var batchComplete = false
  @Published private(set) var isProcessingBatch = false
  @Published private(set) var isUpdatingFavorite = false
  @Published private(set) var deletedCount = 0
  @Published private(set) var reviewedCount = 0
  @Published private(set) var favoriteOverrides: [String: Bool] = [:]

  let availableSizes = [10, 15, 20, 30, 50]

  private let defaults: UserDefaults
  private var reviewedAssetIdentifiers: Set<String>

  private enum DefaultsKey {
    static let reviewedAssetIdentifiers = "PhotoSwipe.reviewedAssetIdentifiers.v2"
    static let batchSize = "PhotoSwipe.batchSize.v2"
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults

    let savedBatchSize = defaults.integer(forKey: DefaultsKey.batchSize)
    let validSizes = [10, 15, 20, 30, 50]
    batchSize = validSizes.contains(savedBatchSize) ? savedBatchSize : 15
    reviewedAssetIdentifiers = Set(
      defaults.stringArray(forKey: DefaultsKey.reviewedAssetIdentifiers) ?? [])

    let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    authorizationStatus = status
    switch status {
    case .notDetermined:
      viewState = .needsPermission
    case .denied:
      viewState = .denied
    case .restricted:
      viewState = .restricted
    case .authorized, .limited:
      viewState = .loading
    @unknown default:
      viewState = .failed("无法确认照片访问权限")
    }
  }

  var currentAsset: PHAsset? {
    guard currentBatchAssets.indices.contains(currentIndex) else { return nil }
    return currentBatchAssets[currentIndex]
  }

  var totalCount: Int { assets.count }

  var remainingCount: Int { max(0, totalCount - reviewedCount) }

  var markedCount: Int { markedAssetIdentifiers.count }

  var batchProgress: String {
    guard !currentBatchAssets.isEmpty else { return "0/0" }
    return "\(currentIndex + 1)/\(currentBatchAssets.count)"
  }

  var isFirstPhoto: Bool { currentIndex == 0 }

  var isLastPhoto: Bool {
    !currentBatchAssets.isEmpty && currentIndex == currentBatchAssets.count - 1
  }

  var currentIsMarked: Bool {
    guard let currentAsset else { return false }
    return markedAssetIdentifiers.contains(currentAsset.localIdentifier)
  }

  var currentIsFavorite: Bool {
    guard let currentAsset else { return false }
    return favoriteOverrides[currentAsset.localIdentifier] ?? currentAsset.isFavorite
  }

  func prepare() {
    let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    authorizationStatus = status
    handleAuthorizationStatus(status, shouldReload: true)
  }

  func requestAuthorization() {
    guard authorizationStatus == .notDetermined else {
      prepare()
      return
    }

    viewState = .requesting
    PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
      Task { @MainActor in
        guard let self else { return }
        self.authorizationStatus = status
        self.handleAuthorizationStatus(status, shouldReload: true)
      }
    }
  }

  func reload(keepingCurrentBatch: Bool = true) {
    let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    authorizationStatus = status
    guard status == .authorized || status == .limited else {
      handleAuthorizationStatus(status, shouldReload: false)
      return
    }
    guard !isProcessingBatch else { return }

    if currentBatchAssets.isEmpty || !keepingCurrentBatch {
      viewState = .loading
    }

    let options = PHFetchOptions()
    options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
    let result = PHAsset.fetchAssets(with: .image, options: options)
    var fetchedAssets: [PHAsset] = []
    fetchedAssets.reserveCapacity(result.count)
    result.enumerateObjects { asset, _, _ in
      fetchedAssets.append(asset)
    }

    applyFetchedAssets(fetchedAssets, keepingCurrentBatch: keepingCurrentBatch)
  }

  func goNext() {
    guard viewState == .ready, !batchComplete, !currentBatchAssets.isEmpty else { return }
    if currentIndex < currentBatchAssets.count - 1 {
      currentIndex += 1
    } else {
      batchComplete = true
    }
  }

  func goPrevious() {
    guard viewState == .ready, !batchComplete, currentIndex > 0 else { return }
    currentIndex -= 1
  }

  func resumeCurrentBatch() {
    guard !currentBatchAssets.isEmpty else { return }
    batchComplete = false
    viewState = .ready
  }

  func toggleMarkCurrent() {
    guard let currentAsset else { return }
    toggleMark(for: currentAsset)
  }

  func toggleMark(for asset: PHAsset) {
    let identifier = asset.localIdentifier
    guard currentBatchAssets.contains(where: { $0.localIdentifier == identifier }) else { return }
    if markedAssetIdentifiers.contains(identifier) {
      markedAssetIdentifiers.remove(identifier)
    } else {
      markedAssetIdentifiers.insert(identifier)
    }
  }

  func isMarked(_ asset: PHAsset) -> Bool {
    markedAssetIdentifiers.contains(asset.localIdentifier)
  }

  func setBatchSize(_ size: Int) {
    guard !isProcessingBatch, availableSizes.contains(size), size != batchSize else { return }
    batchSize = size
    defaults.set(size, forKey: DefaultsKey.batchSize)

    guard !assets.isEmpty else { return }
    let availableAssets = assets.filter { !reviewedAssetIdentifiers.contains($0.localIdentifier) }
    currentBatchAssets = Array(availableAssets.prefix(size))
    let batchIdentifiers = Set(currentBatchAssets.map(\.localIdentifier))
    markedAssetIdentifiers.formIntersection(batchIdentifiers)
    currentIndex = min(currentIndex, max(0, currentBatchAssets.count - 1))
    batchComplete = false
    viewState = currentBatchAssets.isEmpty ? .completed : .ready
  }

  func keepCurrentBatch() {
    guard !isProcessingBatch, batchComplete, !currentBatchAssets.isEmpty else { return }
    let completedIdentifiers = Set(currentBatchAssets.map(\.localIdentifier))
    completeBatch(completedIdentifiers: completedIdentifiers, deleting: [])
  }

  func executeBatchDelete(completion: @escaping (Result<Int, Error>) -> Void) {
    guard !isProcessingBatch else {
      completion(.failure(PhotoLibraryManagerError.operationInProgress))
      return
    }
    guard batchComplete else {
      completion(.failure(PhotoLibraryManagerError.batchNotReady))
      return
    }

    let selectedAssets = currentBatchAssets.filter {
      markedAssetIdentifiers.contains($0.localIdentifier)
    }
    guard !selectedAssets.isEmpty else {
      completion(.failure(PhotoLibraryManagerError.noPhotosSelected))
      return
    }

    isProcessingBatch = true
    let completedIdentifiers = Set(currentBatchAssets.map(\.localIdentifier))
    let deletingIdentifiers = Set(selectedAssets.map(\.localIdentifier))
    PHPhotoLibrary.shared().performChanges(
      {
        PHAssetChangeRequest.deleteAssets(selectedAssets as NSArray)
      },
      completionHandler: { [weak self] success, error in
        Task { @MainActor in
          guard let self else { return }
          if success {
            let count = selectedAssets.count
            self.deletedCount += count
            self.completeBatch(
              completedIdentifiers: completedIdentifiers,
              deleting: deletingIdentifiers
            )
            self.isProcessingBatch = false
            completion(.success(count))
          } else {
            self.isProcessingBatch = false
            completion(.failure(error ?? PhotoLibraryManagerError.deletionFailed))
          }
        }
      }
    )
  }

  func toggleFavoriteCurrent(completion: @escaping (Result<Bool, Error>) -> Void) {
    guard !isUpdatingFavorite else {
      completion(.failure(PhotoLibraryManagerError.operationInProgress))
      return
    }
    guard let asset = currentAsset else {
      completion(.failure(PhotoLibraryManagerError.favoriteUpdateFailed))
      return
    }

    let identifier = asset.localIdentifier
    let newValue = !currentIsFavorite
    isUpdatingFavorite = true
    PHPhotoLibrary.shared().performChanges(
      {
        PHAssetChangeRequest(for: asset).isFavorite = newValue
      },
      completionHandler: { [weak self] success, error in
        Task { @MainActor in
          guard let self else { return }
          self.isUpdatingFavorite = false
          if success {
            var overrides = self.favoriteOverrides
            overrides[identifier] = newValue
            self.favoriteOverrides = overrides
            completion(.success(newValue))
          } else {
            completion(.failure(error ?? PhotoLibraryManagerError.favoriteUpdateFailed))
          }
        }
      }
    )
  }

  func resetProgress() {
    reviewedAssetIdentifiers.removeAll()
    reviewedCount = 0
    persistReviewedIdentifiers()
    markedAssetIdentifiers.removeAll()
    batchComplete = false
    startNextBatch()
  }

  private func handleAuthorizationStatus(_ status: PHAuthorizationStatus, shouldReload: Bool) {
    switch status {
    case .notDetermined:
      clearLoadedData()
      viewState = .needsPermission
    case .denied:
      clearLoadedData()
      viewState = .denied
    case .restricted:
      clearLoadedData()
      viewState = .restricted
    case .authorized, .limited:
      if shouldReload {
        reload(keepingCurrentBatch: true)
      }
    @unknown default:
      clearLoadedData()
      viewState = .failed("无法确认照片访问权限")
    }
  }

  private func applyFetchedAssets(_ fetchedAssets: [PHAsset], keepingCurrentBatch: Bool) {
    let previousBatchIdentifiers =
      keepingCurrentBatch
      ? currentBatchAssets.map(\.localIdentifier)
      : []
    let previousCurrentIdentifier =
      keepingCurrentBatch
      ? currentAsset?.localIdentifier
      : nil

    assets = fetchedAssets
    favoriteOverrides = favoriteOverrides.filter { identifier, _ in
      fetchedAssets.contains(where: { $0.localIdentifier == identifier })
    }

    if authorizationStatus == .authorized {
      let validIdentifiers = Set(fetchedAssets.map(\.localIdentifier))
      let cleanedReviewedIdentifiers = reviewedAssetIdentifiers.intersection(validIdentifiers)
      if cleanedReviewedIdentifiers != reviewedAssetIdentifiers {
        reviewedAssetIdentifiers = cleanedReviewedIdentifiers
        persistReviewedIdentifiers()
      }
    }
    reviewedCount = fetchedAssets.reduce(into: 0) { count, asset in
      if reviewedAssetIdentifiers.contains(asset.localIdentifier) {
        count += 1
      }
    }

    guard !fetchedAssets.isEmpty else {
      currentBatchAssets = []
      markedAssetIdentifiers = []
      currentIndex = 0
      batchComplete = false
      viewState = .empty
      return
    }

    if !previousBatchIdentifiers.isEmpty {
      let assetsByIdentifier = Dictionary(
        uniqueKeysWithValues: fetchedAssets.map { ($0.localIdentifier, $0) }
      )
      let restoredBatch = previousBatchIdentifiers.compactMap { assetsByIdentifier[$0] }
      if !restoredBatch.isEmpty {
        currentBatchAssets = restoredBatch
        let restoredIdentifiers = Set(restoredBatch.map(\.localIdentifier))
        markedAssetIdentifiers.formIntersection(restoredIdentifiers)
        if let previousCurrentIdentifier,
          let restoredIndex = restoredBatch.firstIndex(where: {
            $0.localIdentifier == previousCurrentIdentifier
          })
        {
          currentIndex = restoredIndex
        } else {
          currentIndex = min(currentIndex, restoredBatch.count - 1)
        }
        viewState = .ready
        return
      }
    }

    startNextBatch()
  }

  private func startNextBatch() {
    let availableAssets = assets.filter {
      !reviewedAssetIdentifiers.contains($0.localIdentifier)
    }
    currentBatchAssets = Array(availableAssets.prefix(batchSize))
    currentIndex = 0
    markedAssetIdentifiers.removeAll()
    batchComplete = false
    viewState = currentBatchAssets.isEmpty ? (assets.isEmpty ? .empty : .completed) : .ready
  }

  private func completeBatch(
    completedIdentifiers: Set<String>,
    deleting deletingIdentifiers: Set<String>
  ) {
    reviewedAssetIdentifiers.formUnion(completedIdentifiers)
    persistReviewedIdentifiers()

    if !deletingIdentifiers.isEmpty {
      assets.removeAll { deletingIdentifiers.contains($0.localIdentifier) }
      for identifier in deletingIdentifiers {
        favoriteOverrides.removeValue(forKey: identifier)
      }
    }
    reviewedCount = assets.reduce(into: 0) { count, asset in
      if reviewedAssetIdentifiers.contains(asset.localIdentifier) {
        count += 1
      }
    }

    let activeBatchIdentifiers = Set(currentBatchAssets.map(\.localIdentifier))
    if activeBatchIdentifiers == completedIdentifiers {
      currentBatchAssets = []
      currentIndex = 0
      markedAssetIdentifiers.removeAll()
      batchComplete = false
      startNextBatch()
    } else {
      currentBatchAssets.removeAll {
        deletingIdentifiers.contains($0.localIdentifier)
      }
      markedAssetIdentifiers.subtract(deletingIdentifiers)
      currentIndex = min(currentIndex, max(0, currentBatchAssets.count - 1))
      batchComplete = false
      if currentBatchAssets.isEmpty {
        startNextBatch()
      } else {
        viewState = .ready
      }
    }
  }

  private func persistReviewedIdentifiers() {
    defaults.set(Array(reviewedAssetIdentifiers), forKey: DefaultsKey.reviewedAssetIdentifiers)
  }

  private func clearLoadedData() {
    assets = []
    currentBatchAssets = []
    currentIndex = 0
    markedAssetIdentifiers = []
    batchComplete = false
    reviewedCount = 0
    favoriteOverrides = [:]
  }
}
