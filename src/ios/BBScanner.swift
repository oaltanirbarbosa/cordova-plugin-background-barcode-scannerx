import Foundation
import AVFoundation
import AudioToolbox
import ZXingObjC

@objc(BBScanner)
class BBScanner : CDVPlugin, ZXCaptureDelegate {

    class CameraView: UIView {
        var _capture:ZXCapture?


        //        func interfaceOrientationToVideoOrientation(_ orientation : UIInterfaceOrientation) -> AVCaptureVideoOrientation {
        //            switch (orientation) {
        //            case UIInterfaceOrientation.portrait:
        //                return AVCaptureVideoOrientation.portrait;
        //            case UIInterfaceOrientation.portraitUpsideDown:
        //                return AVCaptureVideoOrientation.portraitUpsideDown;
        //            case UIInterfaceOrientation.landscapeLeft:
        //                return AVCaptureVideoOrientation.landscapeLeft;
        //            case UIInterfaceOrientation.landscapeRight:
        //                return AVCaptureVideoOrientation.landscapeRight;
        //            default:
        //                return AVCaptureVideoOrientation.portraitUpsideDown;
        //            }
        //        }

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

    // var captureSession:AVCaptureSession?
    var captureVideoPreviewLayer:AVCaptureVideoPreviewLayer?
    var metaOutput: AVCaptureMetadataOutput?

    var currentCamera: Int = 0;
    var frontCamera: AVCaptureDevice?
    var backCamera: AVCaptureDevice?

    var scanning: Bool = false
    var paused: Bool = false
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

    // Prepare the scanner with view
    func prepScanner(command: CDVInvokedUrlCommand) -> Bool{
        let status = AVCaptureDevice.authorizationStatus(forMediaType: AVMediaTypeVideo)
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
            self.capture.focusMode = AVCaptureFocusMode.continuousAutoFocus

            cameraView.backgroundColor = UIColor.white
            self.webView!.superview!.insertSubview(cameraView, belowSubview: self.webView!)
            cameraView.addPreviewLayer(self.capture)

            return true
        } catch CaptureError.backCameraUnavailable {
            self.sendErrorCode(command: command, error: ScannerError.back_camera_unavailable)
        } catch CaptureError.frontCameraUnavailable {
            self.sendErrorCode(command: command, error: ScannerError.front_camera_unavailable)
        } catch CaptureError.couldNotCaptureInput(let error){
            print(error.localizedDescription)
            self.sendErrorCode(command: command, error: ScannerError.camera_unavailable)
        } catch {
            self.sendErrorCode(command: command, error: ScannerError.unexpected_error)
        }
        return false
    }

    //    func createCaptureDeviceInput() throws -> AVCaptureDeviceInput {
    //        var captureDevice: AVCaptureDevice
    //        if(currentCamera == 0){
    //            if(backCamera != nil){
    //                captureDevice = backCamera!
    //            } else {
    //                throw CaptureError.backCameraUnavailable
    //            }
    //        } else {
    //            if(frontCamera != nil){
    //                captureDevice = frontCamera!
    //            } else {
    //                throw CaptureError.frontCameraUnavailable
    //            }
    //        }
    //        let captureDeviceInput: AVCaptureDeviceInput
    //        do {
    //            captureDeviceInput = try AVCaptureDeviceInput(device: captureDevice)
    //        } catch let error as NSError {
    //            throw CaptureError.couldNotCaptureInput(error: error)
    //        }
    //        return captureDeviceInput
    //    }

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
        var useMode = AVCaptureTorchMode.on
        if(state == false){
            useMode = AVCaptureTorchMode.off
        }
        do {
            // torch is only available for back camera
            if(backCamera == nil || backCamera!.hasTorch == false || backCamera!.isTorchAvailable == false || backCamera!.isTorchModeSupported(useMode) == false){
                throw LightError.torchUnavailable
            }
            try backCamera!.lockForConfiguration()
            backCamera!.torchMode = useMode
            backCamera!.unlockForConfiguration()
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
            commandDelegate!.send(pluginResult, callbackId: nextScanningCommand?.callbackId!)
            nextScanningCommand = nil
            scanning = false
            self.capture.stop()

//            let deadlineTime = DispatchTime.now() + .milliseconds(500)
//            DispatchQueue.main.asyncAfter(deadline: deadlineTime) {
//                self.capture.start()
//            }

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

    func pageDidLoad() {
        self.webView?.isOpaque = false
        self.webView?.backgroundColor = UIColor.clear
    }

    // ---- BEGIN EXTERNAL API ----

    // Prepare the plugin
    func prepare(_ command: CDVInvokedUrlCommand){
        let status = AVCaptureDevice.authorizationStatus(forMediaType: AVMediaTypeVideo)
        if (status == AVAuthorizationStatus.notDetermined) {
            // Request permission before preparing scanner
            AVCaptureDevice.requestAccess(forMediaType: AVMediaTypeVideo, completionHandler: { (granted) -> Void in
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

    func scan(_ command: CDVInvokedUrlCommand){
        if self.prepScanner(command: command) {
            nextScanningCommand = command
            scanning = true

            self.webView?.isOpaque        = false
            self.webView?.backgroundColor = UIColor.clear
            self.cameraView.isHidden      = false
            if !self.capture.running {
                self.capture.start()
            }
        }
    }

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


    // backCamera is 0, frontCamera is 1

    func useCamera(_ command: CDVInvokedUrlCommand){
        let index = command.arguments[0] as! Int
//        if(currentCamera != index){
//            // camera change only available if both backCamera and frontCamera exist
//            if(backCamera != nil && frontCamera != nil){
//                // switch camera
//                currentCamera = index
//                if(self.prepScanner(command: command)){
//                    do {
//                        captureSession!.beginConfiguration()
//                        let currentInput = captureSession?.inputs[0] as! AVCaptureDeviceInput
//                        captureSession!.removeInput(currentInput)
//                        let input = try self.createCaptureDeviceInput()
//                        captureSession!.addInput(input)
//                        captureSession!.commitConfiguration()
//                        self.getStatus(command)
//                    } catch CaptureError.backCameraUnavailable {
//                        self.sendErrorCode(command: command, error: ScannerError.back_camera_unavailable)
//                    } catch CaptureError.frontCameraUnavailable {
//                        self.sendErrorCode(command: command, error: ScannerError.front_camera_unavailable)
//                    } catch CaptureError.couldNotCaptureInput(let error){
//                        print(error.localizedDescription)
//                        self.sendErrorCode(command: command, error: ScannerError.camera_unavailable)
//                    } catch {
//                        self.sendErrorCode(command: command, error: ScannerError.unexpected_error)
//                    }
//
//                }
//            } else {
//                if(backCamera == nil){
//                    self.sendErrorCode(command: command, error: ScannerError.back_camera_unavailable)
//                } else {
//                    self.sendErrorCode(command: command, error: ScannerError.front_camera_unavailable)
//                }
//            }
//        } else {
//            // immediately return status if camera is unchanged
//            self.getStatus(command)
//        }
    }

    func enableLight(_ command: CDVInvokedUrlCommand) {
        if(self.prepScanner(command: command)){
            self.configureLight(command: command, state: true)
        }
    }

    func disableLight(_ command: CDVInvokedUrlCommand) {
        if(self.prepScanner(command: command)){
            self.configureLight(command: command, state: false)
        }
    }

    // Destroy a plugin
    func destroy(_ command: CDVInvokedUrlCommand) {
        self.makeOpaque()
        if self.cameraView != nil {
            self.cameraView.isHidden = true
        }

        if self.capture != nil {
            self.capture.stop()
            backgroundThread(delay: 0, background: {
                self.cameraView.removePreviewLayer()
                self.cameraView.removeFromSuperview()
                self.cameraView = nil
                self.capture = nil
                self.currentCamera = 0
                self.frontCamera = nil
                self.backCamera = nil
            }, completion: {
                self.getStatus(command)
            })
        } else {
            self.getStatus(command)
        }
    }


    // Return the plugin's status to javscript console
    func getStatus(_ command: CDVInvokedUrlCommand){

        let authorizationStatus = AVCaptureDevice.authorizationStatus(forMediaType: AVMediaTypeVideo);

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
        if(backCamera?.torchMode == AVCaptureTorchMode.on){
            lightEnabled = true
        }

        var canOpenSettings = false
        if #available(iOS 8.0, *) {
            canOpenSettings = true
        }

        var canEnableLight = false
//        if(backCamera?.hasTorch == true && backCamera?.isTorchAvailable == true && backCamera?.isTorchModeSupported(AVCaptureTorchMode.on) == true){
//            canEnableLight = true
//        }

        var canChangeCamera = false;
//        if(backCamera != nil && frontCamera != nil){
//            canChangeCamera = true
//        }

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
    func openSettings(_ command: CDVInvokedUrlCommand) {
        if #available(iOS 10.0, *) {
            guard let settingsUrl = URL(string: UIApplicationOpenSettingsURLString) else {
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
                UIApplication.shared.openURL(NSURL(string: UIApplicationOpenSettingsURLString)! as URL)
                self.getStatus(command)
            } else {
                self.sendErrorCode(command: command, error: ScannerError.open_settings_unavailable)
            }
        }
    }
}
