import CoreLocation
import Flutter
import UIKit

final class LocationTracking: NSObject, CLLocationManagerDelegate, FlutterStreamHandler {
  private let manager = CLLocationManager()
  private let files = FileManager.default
  private lazy var inbox = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("location-inbox")
  private var sink: FlutterEventSink?
  private var pendingStart: FlutterResult?
  private var awaitingAuthorization = false
  private var active = false
  private var error = ""

  override init() {
    super.init()
    manager.delegate = self
    manager.activityType = .automotiveNavigation
    manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    manager.distanceFilter = 10
    manager.pausesLocationUpdatesAutomatically = false
    manager.showsBackgroundLocationIndicator = true
  }

  func register(with messenger: FlutterBinaryMessenger) {
    FlutterEventChannel(name: "driver_tracking/events", binaryMessenger: messenger)
      .setStreamHandler(self)
    FlutterMethodChannel(name: "driver_tracking/methods", binaryMessenger: messenger)
      .setMethodCallHandler { [weak self] call, result in
        self?.handle(call, result: result)
      }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    events(state)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  private var authorized: Bool {
    manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways
  }

  private var state: [String: Any] {
    ["active": active, "authorized": authorized, "error": error]
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    do {
      switch call.method {
      case "state": result(state)
      case "start": requestStart(result)
      case "stop":
        error = ""
        stop()
        result(nil)
      case "read":
        try prepareInbox()
        let urls = try files.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)
        result(try urls.filter { $0.pathExtension == "json" }.prefix(200).map {
          try JSONSerialization.jsonObject(with: Data(contentsOf: $0))
        })
      case "ack":
        for id in call.arguments as? [String] ?? [] where UUID(uuidString: id) != nil {
          let url = inbox.appendingPathComponent(id + ".json")
          if files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
        }
        result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    } catch {
      result(FlutterError(code: "storage", message: error.localizedDescription, details: nil))
    }
  }

  private func prepareInbox() throws {
    try files.createDirectory(at: inbox, withIntermediateDirectories: true)
    var url = inbox
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try url.setResourceValues(values)
  }

  private func requestStart(_ result: @escaping FlutterResult) {
    if pendingStart != nil {
      result(FlutterError(code: "busy", message: "Location permission is already being requested.", details: nil))
      return
    }
    pendingStart = result
    // Core Location's global services check can block while communicating with the system.
    DispatchQueue.global(qos: .userInitiated).async {
      let enabled = CLLocationManager.locationServicesEnabled()
      DispatchQueue.main.async {
        guard self.pendingStart != nil else { return }
        if !enabled {
          self.finishStart(FlutterError(code: "disabled", message: "Turn on Location Services and try again.", details: nil))
        } else if self.manager.authorizationStatus == .notDetermined {
          self.awaitingAuthorization = true
          self.manager.requestWhenInUseAuthorization()
        } else {
          self.startAuthorized()
        }
      }
    }
  }

  private func startAuthorized() {
    guard authorized else {
      finishStart(FlutterError(code: "denied", message: "Allow location access in Settings to start real GPS tracking.", details: nil))
      return
    }
    guard UIApplication.shared.applicationState != .background else {
      finishStart(FlutterError(code: "background", message: "Open Driver Tracking to start GPS.", details: nil))
      return
    }
    error = ""
    manager.allowsBackgroundLocationUpdates = true
    manager.startUpdatingLocation()
    active = true
    sink?(state)
    finishStart(nil)
  }

  private func finishStart(_ value: Any?) {
    let result = pendingStart
    pendingStart = nil
    awaitingAuthorization = false
    result?(value)
  }

  private func stop() {
    manager.stopUpdatingLocation()
    manager.allowsBackgroundLocationUpdates = false
    active = false
    sink?(state)
  }

  private func authorizationChanged() {
    if active && !authorized {
      error = "Location permission or services were disabled."
      stop()
    } else {
      sink?(state)
    }
    if awaitingAuthorization && manager.authorizationStatus != .notDetermined { startAuthorized() }
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    authorizationChanged()
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard active else { return }
    do {
      try prepareInbox()
      for fix in locations where fix.horizontalAccuracy >= 0 {
        let id = UUID().uuidString.lowercased()
        let record: [String: Any] = [
          "id": id, "latitude": fix.coordinate.latitude, "longitude": fix.coordinate.longitude,
          "timestamp": Int64(fix.timestamp.timeIntervalSince1970 * 1000)
        ]
        let data = try JSONSerialization.data(withJSONObject: record)
        try data.write(to: inbox.appendingPathComponent(id + ".json"),
                       options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        sink?(["location": record])
      }
    } catch {
      NSLog("Unable to persist location: %@", error.localizedDescription)
      self.error = "Unable to save a GPS fix. Tracking stopped."
      stop()
    }
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    if (error as? CLError)?.code == .denied {
      self.error = "Location permission or services were disabled."
      stop()
    }
  }
}
