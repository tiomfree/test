///AudioSessionManager.swift
class AudioSessionManager: NSObject, ObservableObject {
    @Published var microphones: [AVCaptureDevice] = []
    var captureSession: AVCaptureSession = .init()
    var audioOutput: AVCaptureAudioDataOutput?
    var configured: Bool = false
    
    private var audioInput: AVCaptureDeviceInput?
    
    let dataOutputQueue = DispatchQueue(label: "audio_queue",
                                        qos: .userInteractive,
                                        attributes: [],
                                        autoreleaseFrequency: .workItem)
    
    override init() {
        super.init()
        microphones = listMicrophones()
    }
    
    func configure(activeMicrophoneName: String?) {
        configureAudioSession(activeMicrophoneName ?? nil) { isSuccessful in
            if isSuccessful {
                self.configured = true
            } else {
                self.configured = false
            }
        }
    }
    
    deinit {
        if captureSession.isRunning {
            captureSession.stopRunning()
        }
        for input in captureSession.inputs {
            captureSession.removeInput(input)
        }
        for output in captureSession.outputs {
            captureSession.removeOutput(output)
        }
        audioOutput = nil
        logger.info("Audio Capture Session deinit")
    }
    
    func checkAudioAuthorization(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                completion(granted)
            }
        default:
            logger.error("App requires audio access")
            completion(false)
        }
    }

    func configureAudioSession(_ activeMicrophoneName: String?, completion: @escaping (Bool) -> Void) {
        checkAudioAuthorization { isAuthorized in
            guard isAuthorized else {
                completion(false)
                return
            }
            self.captureSession.beginConfiguration()
            
            var microphone: AVCaptureDevice
            
            if let activeDevice = self.microphones.first(where: { $0.localizedName == activeMicrophoneName}) {
                microphone = activeDevice
            } else {
                guard let audioDevice = self.microphones.first else {
                    completion(false)
                    return
                }
                microphone = audioDevice
            }
            
            // Add audio input
            do {
                self.audioInput = try AVCaptureDeviceInput(device: microphone)
                if let audioInput = self.audioInput {
                    self.captureSession.addInput(audioInput)
                }
            } catch {
                completion(false)
                logger.error("Error configuring audio input: \(error)")
            }
            
            // Add audio output
            self.audioOutput = AVCaptureAudioDataOutput()
            if let audioOutput = self.audioOutput {
                if self.captureSession.canAddOutput(audioOutput) {
                    self.captureSession.addOutput(audioOutput)
                    
                    let audioConnection = audioOutput.connection(with: .audio)
                    audioConnection?.audioChannels.forEach { channel in
                        channel.isEnabled = true
                    }
                    
                    // Audio settings configured to be compatible with whisper.cpp
                    let audioSettings: [String: Any] = [
                        AVFormatIDKey: kAudioFormatLinearPCM,
                        AVSampleRateKey: 16000,  // Set sample rate to 16kHz
                        AVNumberOfChannelsKey: 1 // Mono
                    ]
                    
                    audioOutput.audioSettings = audioSettings
                }
            }
            
            self.captureSession.commitConfiguration()
            completion(true)
        }
    }
    
    func listMicrophones() -> [AVCaptureDevice] {
        let discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInMicrophone, .externalUnknown], mediaType: .audio, position: .unspecified)
        return discoverySession.devices
    }
    
    func changeDevice(selectedDevice: String) {
        if let name = microphones.first?.localizedName, selectedDevice == "" {
           switchMicrophone(to: name)
        } else {
            switchMicrophone(to: selectedDevice)
        }
    }
    
    func switchMicrophone(to name: String) {
        let discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInMicrophone, .externalUnknown], mediaType: .audio, position: .unspecified)
        
        if let device = discoverySession.devices.first(where: { $0.localizedName == name }) {
            if let existingInput = audioInput {
                captureSession.removeInput(existingInput)
            }
            
            do {
                audioInput = try AVCaptureDeviceInput(device: device)
                if let newInput = audioInput {
                    captureSession.addInput(newInput)
                }
            } catch {
                print("Error switching microphone: \(error)")
            }
        }
    }
    
    func startCapture() {
        captureSession.startRunning()
    }
    
    func stopCapture() {
        captureSession.stopRunning()
    }
}

///capturedelegate.swift
func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        autoreleasepool {
            if let audioFrames = convertSampleBufferToFloatArray(sampleBuffer: sampleBuffer) {
                audioFrameBuffer.append(contentsOf: audioFrames)
                
                if !isTranscribing && audioFrameBuffer.count >= 48000 {
                    let framesToTranscribe = Array(audioFrameBuffer.prefix(100000))
                    
                    Task {
                        do {
                            guard let whisper = self.whisper else { return }
                            isTranscribing = true
                            _ = try await whisper.transcribe(audioFrames: framesToTranscribe)
                            isTranscribing = false
                        } catch {
                            logger.error("\(error)")
                        }
                    }
                    
                    if audioFrameBuffer.count >= 100000 {
                        audioFrameBuffer.removeFirst(100000)
                    }   
                }
            }
        }
    }
    
    func convertSampleBufferToFloatArray(sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return nil
        }
        
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
        
        guard let ptr = dataPointer else {
            return nil
        }
        
        let count = length / MemoryLayout<Float>.size
        let bufferPointer = UnsafeRawPointer(ptr).bindMemory(to: Float.self, capacity: count)
        let audioBuffer = UnsafeBufferPointer(start: bufferPointer, count: count)
        
        return Array(audioBuffer)
    }


///whisperdelegate.swift

extension AudioModifier: WhisperDelegate {
    /// Progress updates as a percentage from 0-1
    func whisper(_ aWhisper: Whisper, didUpdateProgress progress: Double) {}
    
    // MARK: ProcessSegments
    /// Any time a new segments of text have been transcribed
    func whisper(_ aWhisper: Whisper, didProcessNewSegments segments: [Segment], atIndex index: Int) {
        let newText = segments.map(\.text).joined()
        updateCaptions(with: newText)
    }
    
    /// Finished transcribing, includes all transcribed segments of text
    func whisper(_ aWhisper: Whisper, didCompleteWithSegments segments: [Segment]) {}
    
    /// Error with transcription
    func whisper(_ aWhisper: Whisper, didErrorWith error: Error) {
        logger.error("Whisper Error: \(error.localizedDescription)")
    }
    
    func updateCaptions(with newText: String) {
        let trimmedNewText = newText.trimmingCharacters(in: .whitespaces)
        
        if ["[BLANK_AUDIO]", "[BLANK_AUDIO]."].contains(trimmedNewText) {
            return
        }
        
        captionsText = "\(trimmedNewText)"
    }
}
