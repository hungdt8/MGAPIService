import ObjectMapper
import Alamofire
import RxSwift
import RxAlamofire

public func == <K, V>(left: [K:V], right: [K:V]) -> Bool {
    return NSDictionary(dictionary: left).isEqual(to: right)
}

public typealias JSONDictionary = [String: Any]

open class APIBase {
   
    public var manager: Alamofire.SessionManager
    
    public init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        manager = Alamofire.SessionManager(configuration: configuration)
    }
    
    open func requestDataDict<T: Mappable>(_ input: APIInputBase) -> Observable<T> {
        return request(input)
            .map { json -> T in
                guard let dict = json as? JSONDictionary, let t = T(JSON: dict) else {
                    throw APIInvalidResponseError()
                }
                
                return t
            }
    }
    
    open func requestDataList<T: Mappable>(_ input: APIInputBase) -> Observable<[T]> {
        return request(input)
            .map { json -> [T] in
                guard let jsons = json as? [JSONDictionary] else {
                    throw APIInvalidResponseError()
                }
                
                return jsons.compactMap { T(JSON: $0) }
        }
    }
    
    open func request(_ input: APIInputBase) -> Observable<Any> {
        let user = input.user
        let password = input.password
        let urlRequest = preprocess(input)
            .do(onNext: { input in
                print(input)
            })
            .flatMapLatest { [unowned self] input -> Observable<DataRequest> in
                if let uploadInput = input as? APIUploadInputBase {
                    return self.manager.rx
                        .upload(to: uploadInput.urlString,
                                method: uploadInput.requestType,
                                headers: uploadInput.headers) { (multipartFormData) in
                                    input.parameters?.forEach { key, value in
                                        if let data = String(describing: value).data(using:.utf8) {
                                            multipartFormData.append(data, withName: key)
                                        }
                                    }
                                    uploadInput.data.forEach({
                                        multipartFormData.append(
                                            $0.data,
                                            withName: $0.name,
                                            fileName: $0.fileName,
                                            mimeType: $0.mimeType)
                                    })
                        }
                        .map { $0 as DataRequest }
                } else {
                    return self.manager.rx
                        .request(input.requestType,
                                 input.urlString,
                                 parameters: input.parameters,
                                 encoding: input.encoding,
                                 headers: input.headers)
                }
            }
            .do(onNext: { (_) in
                DispatchQueue.main.async {
                    UIApplication.shared.isNetworkActivityIndicatorVisible = true
                }
            })
            .flatMapLatest { dataRequest -> Observable<(HTTPURLResponse, Data)> in
                if let user = user, let password = password {
                    return dataRequest
                        .authenticate(user: user, password: password)
                        .rx.responseData()
                }
                return dataRequest.rx.responseData()
            }
            .do(onNext: { (_) in
                DispatchQueue.main.async {
                    UIApplication.shared.isNetworkActivityIndicatorVisible = false
                }
            }, onError: { (_) in
                DispatchQueue.main.async {
                    UIApplication.shared.isNetworkActivityIndicatorVisible = false
                }
            })
            .map { (dataResponse) -> Any in
                return try self.process(dataResponse)
            }
            .catchError { [unowned self] error -> Observable<Any> in
                return try self.handleRequestError(error, input: input)
            }
            .do(onNext: { (json) in
                if input.useCache {
                    DispatchQueue.global().async {
                        try? CacheManager.sharedInstance.write(urlString: input.urlEncodingString, data: json)
                    }
                }
            })
        
        return urlRequest
        
        let cacheRequest = Observable.just(input)
            .filter { $0.useCache }
            .subscribeOn(ConcurrentDispatchQueueScheduler(queue: DispatchQueue.global()))
            .map {
                try CacheManager.sharedInstance.read(urlString: $0.urlEncodingString)
            }
            .catchError({ (error) -> Observable<Any> in
                print(error)
                return Observable.empty()
            })

        if input.useCache {
            return Observable.concat(cacheRequest, urlRequest).distinctUntilChanged({ (lhs, rhs) -> Bool in
                if let lhsDict = lhs as? JSONDictionary, let rhsDict = rhs as? JSONDictionary {
                    return lhsDict == rhsDict
                } else if let lhsArray = lhs as? [JSONDictionary], let rhsArray = rhs as? [JSONDictionary] {
                    return lhsArray.elementsEqual(rhsArray, by: { (left, right) -> Bool in
                        return left == right
                    })
                } else {
                    return false
                }
            })
        } else {
            return urlRequest
        }
    }
    
    open func preprocess(_ input: APIInputBase) -> Observable<APIInputBase> {
        return Observable.just(input)
    }
    
    open func process(_ response: (HTTPURLResponse, Data)) throws -> Any {
        let (response, data) = response
        let json: Any? = (try? JSONSerialization.jsonObject(with: data, options: []))
        let error: Error
        let statusCode = response.statusCode
        switch statusCode {
        case 200..<300:
            print("👍 [\(statusCode)] " + (response.url?.absoluteString ?? ""))
            return json ?? ""
        default:
            error = handleResponseError(response: response, data: data, json: json)
            print("❌ [\(statusCode)] " + (response.url?.absoluteString ?? ""))
            if let json = json {
                print(json)
            } else {
                print(data)
            }
        }
        throw error
    }
    
    open func handleRequestError(_ error: Error, input: APIInputBase) throws -> Observable<Any> {
        throw error
    }
    
    open func handleResponseError(response: HTTPURLResponse, data: Data, json: Any?) -> Error {
        return APIUnknownError(statusCode: response.statusCode)
    }

}
