import Foundation
import AVFoundation
import AudioToolbox
import ZXingObjC

@objc(BBScanner)
class BBScanner : CDVPlugin, ZXCaptureDelegate {

    class CameraView: UIView {
        var _capture:ZXCapture?

        func addPreviewLayer(_ capture:ZXCapture){

            capture.layer.frame = self.bounds
            self.layer.addSublayer(capture.layer)

            let orientation:UIInterfaceOrientation = UIApplication.shared.statusBarOrientation

            var scanRectRotation:CGFloat;
            var captureRotation:Double;

            switch (orientation) {
                case UIInterfaceOrientation.portrait:
                    captureRotation = 0;
                    scanRectRotation = 90;
                    break;
                case UIInterfaceOrientation.landscapeLeft:
                    captureRotation = 90;
                    scanRectRotation = 180;
                    break;
                case UIInterfaceOrientation.landscapeRight:
                    captureRotation = 270;
                    scanRectRotation = 0;
                    break;
                case UIInterfaceOrientation.portraitUpsideDown:
                    captureRotation = 180;
                    scanRectRotation = 270;
                    break;
                default:
                    captureRotation = 0;
                    scanRectRotation = 90;
                    break;
            }

            capture.transform = CGAffineTransform( rotationAngle: CGFloat((captureRotation / 180 * .pi)) )
            capture.rotation  = scanRectRotation

            self._capture = capture

            // TODO: Create a scanFrame

        }

        func removePreviewLayer() {
            self._capture?.layer.removeFromSuperlayer()
            self._capture = nil
        }

    }

    var cameraView: CameraView!
    var capture: ZXCapture!

    var currentCamera: Int = 0;
    var frontCamera: Int32 = -1;
    var backCamera: Int32 = -1;

    var scanning: Bool = false
    var paused: Bool = false
    var multipleScan: Bool = false
    var nextScanningCommand: CDVInvokedUrlCommand?

    enum ScannerError: Int32 {
        case unexpected_error = 0,
        camera_access_denied = 1,
        camera_access_restricted = 2,
        back_camera_unavailable = 3,
        front_camera_unavailable = 4,
        camera_unavailable = 5,
        scan_canceled = 6,
        light_unavailable = 7,
        open_settings_unavailable = 8
    }

    enum CaptureError: Error {
        case backCameraUnavailable
        case frontCameraUnavailable
        case couldNotCaptureInput(error: NSError)
    }

    enum LightError: Error {
        case torchUnavailable
    }

    override func pluginInitialize() {
        super.pluginInitialize()
        NotificationCenter.default.addObserver(self, selector: #selector(pageDidLoad), name: NSNotification.Name.CDVPageDidLoad, object: nil)
        self.initSubView()
    }

    func initSubView() {
        if self.cameraView == nil {
            self.cameraView = CameraView(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height))
            self.cameraView.autoresizingMask = [.flexibleWidth, .flexibleHeight];
        }
    }

    // Send error to console javascript
    func sendErrorCode(command: CDVInvokedUrlCommand, error: ScannerError){
        let pluginResult = CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: error.rawValue)
        commandDelegate!.send(pluginResult, callbackId:command.callbackId)
    }

    // Prepare the scanner with view
    func prepScanner(command: CDVInvokedUrlCommand) -> Bool{
        let status = AVCaptureDevice.authorizationStatus(for: AVMediaType.video)
        if (status == AVAuthorizationStatus.restricted) {
            self.sendErrorCode(command: command, error: ScannerError.camera_access_restricted)
            return false
        } else if status == AVAuthorizationStatus.denied {
            self.sendErrorCode(command: command, error: ScannerError.camera_access_denied)
            return false
        }

        do {

            if ( self.capture != nil ){
                return true;
            }

            self.initSubView()

            self.capture = ZXCapture.init()
            self.capture.delegate  = self
            self.capture.camera    = self.capture.back()
            self.backCamera = self.capture.back()
            self.frontCamera = self.capture.front()
            self.capture.focusMode = AVCaptureDevice.FocusMode.continuousAutoFocus

            cameraView.backgroundColor = UIColor.white
            self.webView!.superview!.insertSubview(cameraView, belowSubview: self.webView!)
            cameraView.addPreviewLayer(self.capture)

            return true
        } catch {
            self.sendErrorCode(command: command, error: ScannerError.unexpected_error)
        }
        return false
    }

    func makeOpaque(){
        // self.webView?.isOpaque = true
        // self.webView?.backgroundColor = UIColor.white
    }

    func boolToNumberString(bool: Bool) -> String{
        if(bool) {
            return "1"
        } else {
            return "0"
        }
    }

    func configureLight(command: CDVInvokedUrlCommand, state: Bool){

        do {
            if(self.capture.captureDevice == nil ||
                self.capture.captureDevice.hasTorch == false){
                throw LightError.torchUnavailable
            }
            
            try self.capture.captureDevice.lockForConfiguration()
            if (state) {
                try self.capture.captureDevice.setTorchModeOn(level: 1)
            } else {
                if (self.capture.captureDevice.torchMode == AVCaptureDevice.TorchMode.on) {
                    self.capture.captureDevice.torchMode = AVCaptureDevice.TorchMode.off
                }
            }
            self.capture.captureDevice.unlockForConfiguration()

            self.getStatus(command)
        } catch LightError.torchUnavailable {
            self.sendErrorCode(command: command, error: ScannerError.light_unavailable)
        } catch let error as NSError {
            print(error.localizedDescription)
            self.sendErrorCode(command: command, error: ScannerError.unexpected_error)
        }
    }


    // Capture data
    func captureResult(_ capture: ZXCapture!, result: ZXResult!) {
        if ( result == nil || scanning == false ) {
            return;
        }

        if result != nil && result.text != nil {
            let options:Dictionary<String, Any> = self.nextScanningCommand?.arguments[0] as! Dictionary<String, Any>

            if !options.isEmpty {
                if options["format"] != nil {
                    let format:ZXBarcodeFormat = self.stringToBarcodeFormat(format: options["format"] as! String)
                    if ( format != result.barcodeFormat ){
                        return
                    }
                }
            }

            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            let pluginResult = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: result.text)
            pluginResult?.setKeepCallbackAs(multipleScan)
            commandDelegate!.send(pluginResult, callbackId: nextScanningCommand?.callbackId!)

            if !multipleScan {
                nextScanningCommand = nil
                scanning = false
                self.capture.stop()
            }
        }
    }

    // Return an ZXBarcodeFormat from a string
    func stringToBarcodeFormat(format: String)->ZXBarcodeFormat{
        switch format {
            case "AZTEC": return kBarcodeFormatAztec
            case "CODABAR": return kBarcodeFormatCodabar
            case "CODE_39": return kBarcodeFormatCode39
            case "CODE_93": return kBarcodeFormatCode93
            case "CODE_128": return kBarcodeFormatCode128
            case "DATA_MATRIX": return kBarcodeFormatDataMatrix
            case "EAN_8": return kBarcodeFormatEan8
            case "EAN_13": return kBarcodeFormatEan13
            case "ITF": return kBarcodeFormatITF
            case "PDF417": return kBarcodeFormatPDF417
            case "QR_CODE": return kBarcodeFormatQRCode
            case "RSS_14": return kBarcodeFormatRSS14
            case "RSS_EXPANDED": return kBarcodeFormatRSSExpanded
            case "UPC_A": return kBarcodeFormatUPCA
            case "UPC_E": return kBarcodeFormatUPCE
            case "UPC_EAN_EXTENSION": return kBarcodeFormatUPCEANExtension
            default: return kBarcodeFormatEan13
        }
    }

    // Return an String from ZXBarcodeFormat
    func barcodeFormatToString(format:ZXBarcodeFormat)->String {
        switch (format) {
            case kBarcodeFormatAztec: return "AZTEC";
            case kBarcodeFormatCodabar: return "CODABAR";
            case kBarcodeFormatCode39: return "CODE_39";
            case kBarcodeFormatCode93: return "CODE_93";
            case kBarcodeFormatCode128: return "CODE_128";
            case kBarcodeFormatDataMatrix: return "DATA_MATRIX";
            case kBarcodeFormatEan8: return "EAN_8";
            case kBarcodeFormatEan13: return "EAN_13";
            case kBarcodeFormatITF: return "ITF";
            case kBarcodeFormatPDF417: return "PDF417";
            case kBarcodeFormatQRCode: return "QR_CODE";
            case kBarcodeFormatRSS14: return "RSS_14";
            case kBarcodeFormatRSSExpanded: return "RSS_EXPANDED";
            case kBarcodeFormatUPCA: return "UPCA";
            case kBarcodeFormatUPCE: return "UPC_E";
            case kBarcodeFormatUPCEANExtension: return "UPC_EAN_EXTENSION";
            default: return "UNKNOWN";
        }
    }

    @objc func pageDidLoad() {
        self.webView?.isOpaque = false
        self.webView?.backgroundColor = UIColor.clear
    }

    // Create a background thread task
    func backgroundThread(delay: Double = 0.0, background: (() -> Void)? = nil, completion: (() -> Void)? = nil) {
        if #available(iOS 8.0, *) {
            DispatchQueue.global(qos: DispatchQoS.QoSClass.userInitiated).async {
                if (background != nil) {
                    background!()
                }
                DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + delay * Double(NSEC_PER_SEC)) {
                    if(completion != nil){
                        completion!()
                    }
                }
            }
        } else {
            // Fallback for iOS < 8.0
            if(background != nil){
                background!()
            }
            if(completion != nil){
                completion!()
            }
        }
    }
    
    // ---- BEGIN EXTERNAL API ----

    // Prepare the plugin
    @objc
    func prepare(_ command: CDVInvokedUrlCommand){
        let status = AVCaptureDevice.authorizationStatus(for: AVMediaType.video)
        if (status == AVAuthorizationStatus.notDetermined) {
            // Request permission before preparing scanner
            AVCaptureDevice.requestAccess(for: AVMediaType.video, completionHandler: { (granted) -> Void in
                // attempt to prepScanner only after the request returns
                self.backgroundThread(delay: 0, completion: {
                    if(self.prepScanner(command: command)){
                        self.makeOpaque()
                        self.cameraView.isHidden = true
                        self.capture.stop()
                        self.getStatus(command)
                    }
                })
            })
        } else {
            if(self.prepScanner(command: command)){
                self.getStatus(command)
            }
        }
    }

    @objc
    func scan(_ command: CDVInvokedUrlCommand){
        if self.prepScanner(command: command) {
            nextScanningCommand = command
            scanning = true

            if let options = command.argument(at: 0) as? Dictionary<String, Any> {
                if let multipleScan = options["multipleScan"] as? Bool {
                    self.multipleScan = multipleScan
                } else {
                    self.multipleScan = false
                }
            }

            self.webView?.isOpaque        = false
            self.webView?.backgroundColor = UIColor.clear
            self.cameraView.isHidden      = false
            if !self.capture.running {
                self.capture.start()
            }
        }
    }

    @objc
    func pause(_ command: CDVInvokedUrlCommand) {
        scanning = false
        let pluginResult = CDVPluginResult(status: CDVCommandStatus_OK)
        commandDelegate!.send(pluginResult, callbackId:command.callbackId)
    }

    @objc
    func resume(_ command: CDVInvokedUrlCommand) {
        scanning = true
        let pluginResult = CDVPluginResult(status: CDVCommandStatus_OK)
        commandDelegate!.send(pluginResult, callbackId:command.callbackId)
    }

    @objc
    func stop(_ command: CDVInvokedUrlCommand){
        if self.prepScanner(command: command) {
            scanning = false
            self.makeOpaque()
            self.cameraView.isHidden = true
            self.capture.stop()

            if(nextScanningCommand != nil){
                self.sendErrorCode(command: nextScanningCommand!, error: ScannerError.scan_canceled)
            }
            self.getStatus(command)
        }
    }

    @objc
    func snap(_ command: CDVInvokedUrlCommand) {
        if self.prepScanner(command: command) {
            let image = UIImage(cgImage: self.capture.lastScannedImage)
            let resizedImage = image.resizeImage(640, opaque: true)
            let data = resizedImage.pngData()
            let base64 = data?.base64EncodedString()
            let pluginResult = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: base64)
            commandDelegate!.send(pluginResult, callbackId:command.callbackId)
        }
    }


    // backCamera is 0, frontCamera is 1

    @objc
    func useCamera(_ command: CDVInvokedUrlCommand){
        let index = command.arguments[0] as! Int
        if(currentCamera != index){
           // camera change only available if both backCamera and frontCamera exist
           if(backCamera != -1 && frontCamera != -1){
               // switch camera
               currentCamera = index
               if(self.prepScanner(command: command)){
                    if (currentCamera == 0) {
                    self.capture.camera = backCamera
                   } else {
                    self.capture.camera = frontCamera
                   }
                }
           } else {
               if(backCamera == -1){
                   self.sendErrorCode(command: command, error: ScannerError.back_camera_unavailable)
               } else {
                   self.sendErrorCode(command: command, error: ScannerError.front_camera_unavailable)
               }
           }
       } else {
           // immediately return status if camera is unchanged
           self.getStatus(command)
       }
    }

    @objc
    func enableLight(_ command: CDVInvokedUrlCommand) {
        if(self.prepScanner(command: command)){
            self.configureLight(command: command, state: true)
        }
    }

    @objc
    func disableLight(_ command: CDVInvokedUrlCommand) {
        if(self.prepScanner(command: command)){
            self.configureLight(command: command, state: false)
        }
    }

    // Destroy a plugin
    @objc
    func destroy(_ command: CDVInvokedUrlCommand) {
        self.makeOpaque()
        if self.cameraView != nil {
            self.cameraView.isHidden = true
        }

        if self.capture != nil {
            self.capture.stop()
                self.cameraView.removePreviewLayer()
                self.cameraView.removeFromSuperview()
                self.cameraView = nil
                self.capture = nil
                self.currentCamera = 0
                self.getStatus(command)
        } else {
            self.getStatus(command)
        }
    }


    // Return the plugin's status to javscript console
    @objc
    func getStatus(_ command: CDVInvokedUrlCommand){

        let authorizationStatus = AVCaptureDevice.authorizationStatus(for: AVMediaType.video);

        var authorized = false
        if(authorizationStatus == AVAuthorizationStatus.authorized){
            authorized = true
        }

        var denied = false
        if(authorizationStatus == AVAuthorizationStatus.denied){
            denied = true
        }

        var restricted = false
        if(authorizationStatus == AVAuthorizationStatus.restricted){
            restricted = true
        }

        var prepared = false
        if self.capture != nil && self.capture.running == true {
            prepared = true
        }

        var previewing = false
//        if(captureVideoPreviewLayer != nil){
//            previewing = captureVideoPreviewLayer!.connection.isEnabled
//        }

        var showing = false
        if(self.webView!.backgroundColor == UIColor.clear){
            showing = true
        }

        var lightEnabled = false
        var canEnableLight = false
        
        if (self.capture != nil && self.capture.captureDevice != nil) {
            if(self.capture.captureDevice.hasTorch){
                canEnableLight = true
            }
            if(self.capture.captureDevice.isTorchActive){
                lightEnabled = true
            }
        }

        var canOpenSettings = false
        if #available(iOS 8.0, *) {
            canOpenSettings = true
        }

        var canChangeCamera = false;
        if(backCamera != -1 && frontCamera != -1){
            canChangeCamera = true
        }

        let status = [
            "authorized": boolToNumberString(bool: authorized),
            "denied": boolToNumberString(bool: denied),
            "restricted": boolToNumberString(bool: restricted),
            "prepared": boolToNumberString(bool: prepared),
            "scanning": boolToNumberString(bool: self.scanning),
            "previewing": boolToNumberString(bool: previewing),
            "showing": boolToNumberString(bool: showing),
            "lightEnabled": boolToNumberString(bool: lightEnabled),
            "canOpenSettings": boolToNumberString(bool: canOpenSettings),
            "canEnableLight": boolToNumberString(bool: canEnableLight),
            "canChangeCamera": boolToNumberString(bool: canChangeCamera),
            "currentCamera": String(currentCamera)
        ]

        let pluginResult = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: status)
        commandDelegate!.send(pluginResult, callbackId:command.callbackId)
    }


    // Open native settings
    @objc
    func openSettings(_ command: CDVInvokedUrlCommand) {
        if #available(iOS 10.0, *) {
            guard let settingsUrl = URL(string: UIApplication.openSettingsURLString) else {
                return
            }
            if UIApplication.shared.canOpenURL(settingsUrl) {
                UIApplication.shared.open(settingsUrl, completionHandler: { (success) in
                    self.getStatus(command)
                })
            } else {
                self.sendErrorCode(command: command, error: ScannerError.open_settings_unavailable)
            }
        } else {
            // pre iOS 10.0
            if #available(iOS 8.0, *) {
                UIApplication.shared.openURL(NSURL(string: UIApplication.openSettingsURLString)! as URL)
                self.getStatus(command)
            } else {
                self.sendErrorCode(command: command, error: ScannerError.open_settings_unavailable)
            }
        }
    }
}

extension UIImage {
    func resizeImage(_ dimension: CGFloat, opaque: Bool, contentMode: UIView.ContentMode = .scaleAspectFit) -> UIImage {
        var width: CGFloat
        var height: CGFloat
        var newImage: UIImage

        let size = self.size
        let aspectRatio =  size.width/size.height

        switch contentMode {
            case .scaleAspectFit:
                if aspectRatio > 1 {                            // Landscape image
                    width = dimension
                    height = dimension / aspectRatio
                } else {                                        // Portrait image
                    height = dimension
                    width = dimension * aspectRatio
                }

        default:
            fatalError("UIIMage.resizeToFit(): FATAL: Unimplemented ContentMode")
        }

        if #available(iOS 10.0, *) {
            let renderFormat = UIGraphicsImageRendererFormat.default()
            renderFormat.opaque = opaque
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: renderFormat)
            newImage = renderer.image {
                (context) in
                self.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        } else {
            UIGraphicsBeginImageContextWithOptions(CGSize(width: width, height: height), opaque, 0)
                self.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
                newImage = UIGraphicsGetImageFromCurrentImageContext()!
            UIGraphicsEndImageContext()
        }

        return newImage
    }
}