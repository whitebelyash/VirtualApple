//
//  VirtualMachine.swift
//  VirtualApple
//
//  Created by Saagar Jha on 11/20/21.
//

import Foundation
import Virtualization
import Dynamic

@objc protocol _VZVirtualMachine {
	@available(macOS, obsoleted: 13)
	@objc(_startWithOptions:completionHandler:)
	func _start(with options: _VZVirtualMachineStartOptions) async throws
}


// TODO: this should be reworked as it breaks building the project with macOS13+ deployment target
@objc protocol _VZVirtualMachineStartOptions {
	init()
	@available(macOS, obsoleted: 13)
	var panicAction: Bool { get set }
	@available(macOS, obsoleted: 13)
	var stopInIBootStage1: Bool { get set }
	@available(macOS, obsoleted: 13)
	var stopInIBootStage2: Bool { get set }
	@available(macOS, obsoleted: 13)
	var bootMacOSRecovery: Bool { get set }
	@available(macOS, obsoleted: 13)
	var forceDFU: Bool { get set }

	@available(macOS 13, *)
	var _panicAction: Bool { get @objc(_setPanicAction:) set }
	@available(macOS 13, *)
	var _stopInIBootStage1: Bool { get @objc(_setStopInIBootStage1:) set }
	@available(macOS 13, *)
	var _stopInIBootStage2: Bool { get @objc(_setStopInIBootStage2:) set }
	@available(macOS 13, *)
	var _forceDFU: Bool { get @objc(_setForceDFU:) set }
}

struct Configuration: Codable {
	var cpuCount: Int
	var memorySize: UInt64
	var screenWidth: Int
	var screenHeight: Int
	var screenScale: Int
	var bootIntoMacOSRecovery: Bool
	var bootIntoDFU: Bool
	var haltOnPanic: Bool
	var haltInIBoot1: Bool
	var haltInIBoot2: Bool
	var debugPort: Int?
    var romURL: URL?
}

struct Metadata: Codable {
	var configuration: Configuration?
	var installed = false
	var machineIdentifier: Data?
	var hardwareModel: Data?
}

@MainActor
class VirtualMachine: NSObject, VZVirtualMachineDelegate {
	var metadata: Metadata
	let url: URL
	var virtualMachine: VZVirtualMachine!
	var hardwareModel: VZMacHardwareModel!
	var machineIdentifier: VZMacMachineIdentifier!
	var installProgress: Progress!
	var running: Bool = false

	init(creatingAt url: URL) throws {
		self.url = url
		metadata = Metadata()
		super.init()
		try? FileManager.default.removeItem(at: url)
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		try saveMetadata()
	}

	init(opening url: URL) throws {
		self.url = url
		metadata = try JSONDecoder().decode(Metadata.self, from: Data(contentsOf: url.appendingPathComponent("metadata.json")))
		if metadata.installed {
			hardwareModel = VZMacHardwareModel(dataRepresentation: metadata.hardwareModel!)!
			machineIdentifier = VZMacMachineIdentifier(dataRepresentation: metadata.machineIdentifier!)!
		}
	}

    func install(ipsw: URL?, diskSize: Int) async throws {
		FileManager.default.createFile(atPath: url.appendingPathComponent("disk.img").path, contents: nil)
		let handle = try FileHandle(forWritingTo: url.appendingPathComponent("disk.img"))
		try handle.truncate(atOffset: UInt64(diskSize) << 30)
        
        if let url = ipsw {
            let image = try await VZMacOSRestoreImage.image(from: url)
            hardwareModel = image.mostFeaturefulSupportedConfiguration!.hardwareModel
        }
        // Manual setup
        else {
            let hardwareDescriptor = Dynamic._VZMacHardwareModelDescriptor()
            //hardwareDescriptor.setISA(1)
            hardwareDescriptor.setPlatformVersion(2) // 2 - vma2macos
            hardwareDescriptor.setBoardID(0x20) // VirtualMac2,1
            hardwareModel = Dynamic.VZMacHardwareModel._hardwareModelWithDescriptor(hardwareDescriptor.asObject)
        }
		metadata.hardwareModel = hardwareModel!.dataRepresentation
		machineIdentifier = VZMacMachineIdentifier()
		metadata.machineIdentifier = machineIdentifier.dataRepresentation
		try setupVirtualMachine()
        if let url = ipsw {
            let installer = VZMacOSInstaller(virtualMachine: virtualMachine, restoringFromImageAt: url)
            installProgress = installer.progress
            try await installer.install()
        }
		metadata.installed = true
		try saveMetadata()
	}

	func setupVirtualMachine() throws {
		let configuration = metadata.configuration!

		let vmConfiguration = VZVirtualMachineConfiguration()
        let bootLoader = VZMacOSBootLoader()
        if let romURL = configuration.romURL {
            if FileManager.default.fileExists(atPath: romURL.path) {
                Dynamic(bootLoader)._setROMURL(romURL)
            }
        }
        
        vmConfiguration.bootLoader = bootLoader
		let platform = VZMacPlatformConfiguration()
		platform.hardwareModel = hardwareModel
		platform.auxiliaryStorage = try VZMacAuxiliaryStorage(creatingStorageAt: url.appendingPathComponent("aux.img"), hardwareModel: hardwareModel, options: .allowOverwrite)
		platform.machineIdentifier = machineIdentifier
        let serial = Dynamic._VZPL011SerialPortConfiguration()
        let serial_attachment = VZFileHandleSerialPortAttachment.init(fileHandleForReading: FileHandle.standardInput, fileHandleForWriting: FileHandle.standardOutput)
        serial.Attachment = serial_attachment
        vmConfiguration.serialPorts.append(unsafeBitCast(serial.asObject, to: VZSerialPortConfiguration.self))
		vmConfiguration.platform = platform
		vmConfiguration.cpuCount = configuration.cpuCount
		vmConfiguration.memorySize = configuration.memorySize

		let graphics = VZMacGraphicsDeviceConfiguration()
		graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: configuration.screenWidth * configuration.screenScale, heightInPixels: configuration.screenHeight * configuration.screenScale, pixelsPerInch: 100 * configuration.screenScale)]
		vmConfiguration.graphicsDevices = [graphics]

		vmConfiguration.keyboards = [VZUSBKeyboardConfiguration()]
		if #available(macOS 13, *) {
			vmConfiguration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration(), VZMacTrackpadConfiguration()]
		} else {
			vmConfiguration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
		}
		vmConfiguration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
		let network = VZVirtioNetworkDeviceConfiguration()
		network.attachment = VZNATNetworkDeviceAttachment()
		vmConfiguration.networkDevices = [network]
		vmConfiguration.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: url.appendingPathComponent("disk.img"), readOnly: false))]

		if let debugPort = configuration.debugPort {
            let debugStub = Dynamic._VZGDBDebugStubConfiguration(port: debugPort)
            Dynamic(vmConfiguration)._debugStub = debugStub.asObject
		}

		virtualMachine = VZVirtualMachine(configuration: vmConfiguration)
		virtualMachine.delegate = self
	}

	func start() async throws {
		let configuration = metadata.configuration!

		func populateFromConfiguration(_ options: _VZVirtualMachineStartOptions) {
			if #available(macOS 13, *) {
				//options._panicAction = configuration.haltOnPanic
				options._stopInIBootStage1 = configuration.haltInIBoot1
				options._stopInIBootStage2 = configuration.haltInIBoot2
				options._forceDFU = configuration.bootIntoDFU
			} else {
				//options.panicAction = configuration.haltOnPanic
				options.stopInIBootStage1 = configuration.haltInIBoot1
				options.stopInIBootStage2 = configuration.haltInIBoot2
				options.forceDFU = configuration.bootIntoDFU
			}
		}

		if #available(macOS 13, *) {
			let options = VZMacOSVirtualMachineStartOptions()
			options.startUpFromMacOSRecovery = configuration.bootIntoMacOSRecovery
			populateFromConfiguration(unsafeBitCast(options, to: _VZVirtualMachineStartOptions.self))
			try await virtualMachine.start(options: options)
        } else {
            let options = unsafeBitCast(NSClassFromString("_VZVirtualMachineStartOptions")!, to: _VZVirtualMachineStartOptions.Type.self).init()
            populateFromConfiguration(options)
            options.bootMacOSRecovery = configuration.bootIntoMacOSRecovery
            try await unsafeBitCast(virtualMachine, to: _VZVirtualMachine.self)._start(with: options)
        }

		running = true
        print("Starting VM (DFU: \(metadata.configuration!.bootIntoDFU.description))")
        if let romURL = metadata.configuration!.romURL {
            print("Using custom AVPBooter at \(romURL.path)")
        }
	}

	func stop() async throws {
		defer {
            print("VM is stopping")
			running = false
		}
		try await virtualMachine.stop()
	}

	func saveMetadata() throws {
		try JSONEncoder().encode(metadata).write(to: url.appendingPathComponent("metadata.json"))
	}

	nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
		unsafelyRunOnMainActor {
			running = false
		}
	}

	nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
		unsafelyRunOnMainActor {
			running = false
		}
	}
}
