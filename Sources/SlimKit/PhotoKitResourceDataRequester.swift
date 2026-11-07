import Foundation
import Photos

protocol ResourceDataRequester: Sendable {
    func requestData(
        isNetworkAccessAllowed: Bool,
        progressHandler: @escaping (Double) -> Void,
        dataReceivedHandler: @escaping (Data) -> Void,
        completionHandler: @escaping (Error?) -> Void
    ) -> PHAssetResourceDataRequestID

    func cancelDataRequest(_ requestID: PHAssetResourceDataRequestID)
}

final class PhotoKitResourceDataRequester: ResourceDataRequester, @unchecked Sendable {
    private let resource: PHAssetResource

    init(resource: PHAssetResource) {
        self.resource = resource
    }

    func requestData(
        isNetworkAccessAllowed: Bool,
        progressHandler: @escaping (Double) -> Void,
        dataReceivedHandler: @escaping (Data) -> Void,
        completionHandler: @escaping (Error?) -> Void
    ) -> PHAssetResourceDataRequestID {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = isNetworkAccessAllowed
        options.progressHandler = progressHandler
        return PHAssetResourceManager.default().requestData(
            for: resource,
            options: options,
            dataReceivedHandler: dataReceivedHandler,
            completionHandler: completionHandler
        )
    }

    func cancelDataRequest(_ requestID: PHAssetResourceDataRequestID) {
        PHAssetResourceManager.default().cancelDataRequest(requestID)
    }
}
