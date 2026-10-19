import Foundation
import CallKit
import AVFoundation

final class CallKitManager: NSObject {
    private let provider: CXProvider
    private var currentUUID: UUID?
    private var answerAction: CXAnswerCallAction?

    var onStart: ((String) -> Void)?
    var onAnswer: (() -> Void)?
    var onEnd: (() -> Void)?
    var onMute: ((Bool) -> Void)?
    var onDTMF: ((String) -> Void)?
    var onAudioActivated: (() -> Void)?
    var onAudioDeactivated: (() -> Void)?
    var onPrepareAudio: (() -> Void)?
    var onLog: ((String) -> Void)?

    override init() {
        let configuration = CXProviderConfiguration(localizedName: "J7Bridge")
        configuration.supportsVideo = false
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.phoneNumber]
        configuration.includesCallsInRecents = true
        provider = CXProvider(configuration: configuration)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    func reportIncoming(number: String, callerName: String?) {
        guard currentUUID == nil else {
            onLog?("[CALLKIT] duplicate incoming ignored")
            return
        }
        let uuid = UUID()
        currentUUID = uuid

        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .phoneNumber, value: number)
        update.localizedCallerName = callerName
        update.hasVideo = false
        update.supportsDTMF = true
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false

        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            if let error {
                let nsError = error as NSError
                self?.onLog?("[CALLKIT] ERROR domain=\(nsError.domain) code=\(nsError.code)")
                self?.onLog?("[CALLKIT] ERROR description=\(nsError.localizedDescription)")
                self?.onLog?("[CALLKIT] ERROR userInfo=\(nsError.userInfo)")
                self?.currentUUID = nil
            } else {
                self?.onLog?("[CALLKIT] INCOMING UI REPORTED UUID=\(uuid.uuidString)")
            }
        }
    }

    func startOutgoing(number: String) {
        let uuid = UUID()
        currentUUID = uuid
        let handle = CXHandle(type: .phoneNumber, value: number)
        let action = CXStartCallAction(call: uuid, handle: handle)
        action.isVideo = false
        let transaction = CXTransaction(action: action)
        CXCallController().request(transaction) { [weak self] error in
            if let error {
                self?.onLog?("[CALLKIT] start outgoing failed: \(error.localizedDescription)")
                self?.currentUUID = nil
            } else {
                self?.onLog?("[CALLKIT] OUTGOING transaction accepted UUID=\(uuid.uuidString)")
            }
        }
    }

    func endCurrentCall() {
        guard let uuid = currentUUID else { return }
        let transaction = CXTransaction(action: CXEndCallAction(call: uuid))
        CXCallController().request(transaction) { [weak self] error in
            if let error { self?.onLog?("[CALLKIT] local end failed: \(error.localizedDescription)") }
        }
    }

    func fulfillAnswerIfNeeded() {
        answerAction?.fulfill()
        answerAction = nil
    }

    func reportOutgoingConnecting() {
        guard let uuid = currentUUID else { return }
        provider.reportOutgoingCall(with: uuid, startedConnectingAt: Date())
    }

    func reportOutgoingConnected() {
        guard let uuid = currentUUID else { return }
        provider.reportOutgoingCall(with: uuid, connectedAt: Date())
    }

    func reportRemoteEnd(reason: CXCallEndedReason = .remoteEnded) {
        guard let uuid = currentUUID else { return }
        provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
        currentUUID = nil
        answerAction = nil
        // AppModel.handleRemoteEnd() already closes the voice gate and stops the
        // engine synchronously. Avoid issuing a second, untagged deactivation here;
        // CallKit's didDeactivate callback may arrive after a subsequent call starts.
    }

    func clearCurrentCall() {
        currentUUID = nil
        answerAction = nil
    }
}

extension CallKitManager: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        currentUUID = nil
        answerAction = nil
        onAudioDeactivated?()
        onLog?("[CALLKIT] provider reset")
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        currentUUID = action.callUUID
        onPrepareAudio?()
        onLog?("[CALLSHARE_AUDIO_R1] PREPARE before CallKit activation (outgoing)")
        reportOutgoingConnecting()
        onLog?("[CALLKIT] START action -> BLE MAKE CALL")
        onStart?(action.handle.value)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        answerAction = action
        onPrepareAudio?()
        onLog?("[CALLSHARE_AUDIO_R1] PREPARE before CallKit activation (answer)")
        onLog?("[CALLKIT] ANSWER action -> BLE 05; waiting for K7 05")
        onAnswer?()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        onLog?("[CALLKIT] END action -> BLE 04")
        onEnd?()
        action.fulfill()
        currentUUID = nil
        answerAction = nil
        // onEnd (AppModel) closes audio before this action is fulfilled. Let the
        // provider's didDeactivate notification represent the system transition.
    }

    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        action.fail()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        onMute?(action.isMuted)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
        onDTMF?(action.digits)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        onLog?("[CALLSHARE_AUDIO_R1] didActivate CALLED")
        onLog?("[CALLSHARE_AUDIO_R1] session category=\(audioSession.category.rawValue)")
        onLog?("[CALLSHARE_AUDIO_R1] session mode=\(audioSession.mode.rawValue)")
        onLog?("[CALLSHARE_AUDIO_R1] sampleRate=\(audioSession.sampleRate)")
        onLog?("[CALLSHARE_AUDIO_R1] inputChannels=\(audioSession.inputNumberOfChannels)")
        onLog?("[CALLSHARE_AUDIO_R1] outputChannels=\(audioSession.outputNumberOfChannels)")
        onLog?("[CALLSHARE_AUDIO_R1] ioBuffer=\(audioSession.ioBufferDuration)")
        let route = audioSession.currentRoute
        let inputs = route.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        let outputs = route.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        onLog?("[CALLSHARE_AUDIO_R1] route IN[\(inputs)] OUT[\(outputs)]")
        onLog?("[CALLSHARE_AUDIO_R1] hardwareSampleRate=\(audioSession.sampleRate)")
        onLog?("[CALLKIT] audio session ACT")
        onAudioActivated?()
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        // CallKit callbacks do not carry the UUID whose audio session changed.
        // If a new call is already current, a late deactivation from the previous
        // call must not tear down the new call's audio engine.
        if let currentUUID {
            onLog?("[CALLKIT] DID_DEACTIVATE ignored; live call UUID=\(currentUUID.uuidString)")
            return
        }
        onLog?("[CALLSHARE_AUDIO_R1] didDeactivate CALLED")
        onLog?("[CALLKIT] audio session DEACT")
        onAudioDeactivated?()
    }
}
