//
//  RunModel.swift
//  RaceRunner
//
//  Created by Joshua Adams on 3/13/15.
//  Copyright (c) 2015 Josh Adams. All rights reserved.
//

import Foundation
import MapKit
import CoreLocation
import CoreData

protocol ImportedRunDelegate {
  func runWasImported()
}

class RunModel: NSObject, CLLocationManagerDelegate, PubNubPublisher {
  var locations: [CLLocation]! = []
  var status : Status = .PreRun
  var runDelegate: RunDelegate?
  var importedRunDelegate: ImportedRunDelegate?
  var run: Run!
  var realRunInProgress = false
  var totalDistance = 0.0
  private var currentAltitude = 0.0
  private var oldSplitAltitude = 0.0
  private var currentSplitDistance = 0.0
  private var totalSeconds = 0
  private var splitsCompleted = 0
  private var shouldReportSplits = false
  private var lastDistance = 0.0
  private var lastSeconds = 0
  private var reportEvery = SettingsManager.never
  private var temperature: Float = 0.0
  private var weather = ""
  private var timer: NSTimer!
  private var initialLocation: CLLocation!
  private var locationManager: LocationManager!
  private var autoName = Run.noAutoName
  private var didSetAutoNameAndFirstLoc = false
  private var altGained  = 0.0
  private var altLost = 0.0
  private var minLong = 0.0
  private var maxLong = 0.0
  private var minLat = 0.0
  private var maxLat = 0.0
  private var minAlt = 0.0
  private var maxAlt = 0.0
  private var curAlt = 0.0
  private var runToSimulate: Run!
  private var gpxFile: String!
  private var secondLength = 1.0
  private var spectatorStoppedRun = false
  private (set) var sortedAltitudes: [Double] = []
  private (set) var sortedPaces: [Double] = []
  static let altFudge: Double = 0.1
  static let minDistance = 400.0
  private static let distanceTolerance: Double = 0.05
  private static let coordinateTolerance: Double = 0.0000050
  private static let minAccuracy: CLLocationDistance = 20.0
  private static let distanceFilter: CLLocationDistance = 10.0
  private static let freezeDriedAccuracy: CLLocationAccuracy = 5.0
  private static let defaultTemperature: Float = 25.0
  private static let defaultWeather = "sunny"
  private static let importSucceededMessage = "Successfully imported run"
  private static let importFailedMessage = "Run import failed."
  private static let importRunTitle = "Import Run"
  private static let ok = "OK"
  
  enum Status {
    case PreRun
    case InProgress
    case Paused
  }
  
  static let runModel = RunModel()
      
  class func initializeRunModelWithGpxFile(gpxFile: String) {
    runModel.gpxFile = gpxFile
    runModel.runToSimulate = nil
    runModel.locationManager = LocationManager(gpxFile: gpxFile)
    finishSimulatorSetup()
  }
  
  class func initializeRunModelWithRun(run: Run) {
    runModel.runToSimulate = run
    runModel.gpxFile = nil
    var cLLocations: [CLLocation] = []
    for uncastedLocation in run.locations {
      let location = uncastedLocation as! Location
      cLLocations.append(CLLocation(coordinate: CLLocationCoordinate2D(latitude: location.latitude.doubleValue, longitude: location.longitude.doubleValue), altitude: location.altitude.doubleValue, horizontalAccuracy: RunModel.freezeDriedAccuracy, verticalAccuracy: RunModel.freezeDriedAccuracy, timestamp: location.timestamp))
    }
    runModel.locationManager = LocationManager(locations: cLLocations)
    finishSimulatorSetup()
  }
  
  class func registerForImportedRunNotifications(importedRunDelegate: ImportedRunDelegate) {
    runModel.importedRunDelegate = importedRunDelegate
  }
  
  class func deregisterForImportedRunNotifications() {
    runModel.importedRunDelegate = nil
  }
  
  class func finishSimulatorSetup() {
    runModel.secondLength /= SettingsManager.getMultiplier()
    runModel.locationManager.secondLength = runModel.secondLength
    runModel.status = .PreRun
    configureLocationManager()
    runModel.locationManager.startUpdatingLocation()
  }
  
  class func initializeRunModel() {
    runModel.runToSimulate = nil
    runModel.gpxFile = nil
    runModel.secondLength = 1.0
    if runModel.locationManager == nil {
      runModel.locationManager = LocationManager()
      configureLocationManager()
    }
    runModel.locationManager.startUpdatingLocation()
  }
  
  class func configureLocationManager() {
    runModel.locationManager.delegate = runModel
    runModel.locationManager.desiredAccuracy = kCLLocationAccuracyBest
    runModel.locationManager.distanceFilter = kCLDistanceFilterNone // This is the default. Explicit is good.
    runModel.locationManager.activityType = .Fitness
    runModel.locationManager.requestAlwaysAuthorization()
    runModel.locationManager.distanceFilter = RunModel.distanceFilter
    runModel.locationManager.pausesLocationUpdatesAutomatically = false
    runModel.locationManager.allowsBackgroundLocationUpdates = true
    runModel.locationManager.startUpdatingLocation()
  }
  
  func locationManager(manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    switch status {
    case .PreRun:
      initialLocation = locations[0]
      runDelegate?.showInitialCoordinate(initialLocation.coordinate)
      locationManager?.stopUpdatingLocation()
      if runToSimulate == nil && gpxFile == nil {
        DarkSky().currentWeather(CLLocationCoordinate2D(
          latitude: initialLocation.coordinate.latitude,
          longitude: initialLocation.coordinate.longitude) ) { result in
            switch result {
            case .Error(_, _):
              self.temperature = Run.noTemperature
              self.weather = Run.noWeather
            case .Success(_, let dictionary):
              if dictionary != nil {
                self.temperature = Converter.convertFahrenheitToCelsius(dictionary["currently"]!["apparentTemperature"] as! Float)
                self.weather = dictionary["currently"]!["summary"] as! String
                //let synth = AVSpeechSynthesizer()
                //var utterance = AVSpeechUtterance(string: self.weather)
                //utterance.rate = 0.3
                //synth.speakUtterance(utterance)
              }
              else {
                self.temperature = Run.noTemperature
                self.weather = Run.noWeather
              }
            }
          }
      }
    case .InProgress:
      for location in locations {
        let newLocation: CLLocation = location
        if abs(newLocation.horizontalAccuracy) < RunModel.minAccuracy {
          if self.locations.count > 0 {
            let altitudeIndex = sortedAltitudes.insertionIndexOf(newLocation.altitude) { $0 < $1 }
            sortedAltitudes.insert(newLocation.altitude, atIndex: altitudeIndex)
            let altitudeColor = UiHelpers.colorForValue(newLocation.altitude, sortedArray: sortedAltitudes, index: altitudeIndex)
            
            let distanceDelta = newLocation.distanceFromLocation(self.locations.last!)
            totalDistance += distanceDelta
            let timeDelta = newLocation.timestamp.timeIntervalSinceDate(self.locations.last!.timestamp)
            let pace = distanceDelta / timeDelta
            let paceIndex = sortedPaces.insertionIndexOf(pace) { $0 < $1 }
            sortedPaces.insert(pace, atIndex: paceIndex)
            let paceColor = UiHelpers.colorForValue(pace, sortedArray: sortedPaces, index: paceIndex)
            runDelegate?.plotToCoordinate(newLocation.coordinate, altitudeColor: altitudeColor, paceColor: paceColor)
          }
          else {
            runDelegate?.showInitialCoordinate(newLocation.coordinate)
          }
          self.locations.append(newLocation)
        }
        
        if !didSetAutoNameAndFirstLoc {
          didSetAutoNameAndFirstLoc = true
          if runToSimulate == nil && gpxFile == nil {
            CLGeocoder().reverseGeocodeLocation(newLocation, completionHandler: {(placemarks, error) in
              if error == nil {
                if placemarks?.count > 0 {
                  let placemark = placemarks![0]
                  if let thoroughfare = placemark.thoroughfare {
                    self.autoName = thoroughfare
                  }
                }
                else {
                  self.autoName = Run.noAutoName
                }
              }
              else {
                self.autoName = Run.noAutoName
              }
            })
          }
          oldSplitAltitude = newLocation.altitude
          minAlt = newLocation.altitude
          maxAlt = newLocation.altitude
          minLong = newLocation.coordinate.longitude
          maxLong = newLocation.coordinate.longitude
          minLat = newLocation.coordinate.latitude
          maxLat = newLocation.coordinate.latitude
        }
        else {
          if newLocation.coordinate.latitude < minLat {
            minLat = newLocation.coordinate.latitude
          }
          if newLocation.coordinate.longitude < minLong {
            minLong = newLocation.coordinate.longitude
          }
          if newLocation.coordinate.latitude > maxLat {
            maxLat = newLocation.coordinate.latitude
          }
          if newLocation.coordinate.longitude > maxLong {
            maxLong = newLocation.coordinate.longitude
          }
          if newLocation.altitude < minAlt {
            minAlt = newLocation.altitude
          }
          if newLocation.altitude > maxAlt {
            maxAlt = newLocation.altitude
          }
          if newLocation.altitude > curAlt + RunModel.altFudge {
            altGained += newLocation.altitude - curAlt
          }
          if newLocation.altitude < curAlt - RunModel.altFudge {
            altLost += curAlt - newLocation.altitude
          }
        }
        curAlt = newLocation.altitude
      }
    case .Paused:
      break
    }
  }
  
  func eachSecond() {
    if status == .InProgress {
      totalSeconds++
      if SettingsManager.getBroadcastNextRun() && locations.count > 0 && realRunInProgress {
        PubNubManager.publishLocation(locations[locations.count - 1], distance: totalDistance, seconds: totalSeconds, publisher: SettingsManager.getBroadcastName())
      }
      runDelegate?.receiveProgress(totalDistance, totalSeconds: totalSeconds, altitude: curAlt, altGained: altGained, altLost: altLost)
      currentSplitDistance = totalDistance - lastDistance
      if shouldReportSplits && currentSplitDistance >= reportEvery {
        splitsCompleted++
        currentSplitDistance -= reportEvery
        if (SettingsManager.getAudibleSplits()) {
          Converter.announceProgress(totalSeconds, lastSeconds: lastSeconds, totalDistance: totalDistance, lastDistance: lastDistance, newAltitude: curAlt, oldAltitude: oldSplitAltitude)
            // TODO: Add a preference to optionally display current split pace. Invoke the delegate
            // with what it needs to know to display current split pace. If the preference is set,
            // have the delegate display current split pace.
        }
        lastDistance = totalDistance
        lastSeconds = totalSeconds
        oldSplitAltitude = curAlt
      }
    }
  }
  
  func start() {
    status = .InProgress
    reportEvery = SettingsManager.getReportEvery()
    if reportEvery == SettingsManager.never {
      shouldReportSplits = false
    }
    else {
      shouldReportSplits = true
    }
    
    oldSplitAltitude = 0.0
    lastSeconds = 0
    totalDistance = 0.0
    lastDistance = 0.0
    currentAltitude = 0.0
    currentSplitDistance = 0.0
    splitsCompleted = 0
    altGained = 0.0
    altLost = 0.0
    locationManager.startUpdatingLocation()
    startTimer()
    if runToSimulate == nil && gpxFile == nil {
      realRunInProgress = true
    }
    if SettingsManager.getBroadcastNextRun() && realRunInProgress {
      PubNubManager.subscribeToChannel(self, publisher: SettingsManager.getBroadcastName())
    }
  }
  
  class func addRun(url: NSURL) -> Bool {
    var succeeded = true
    var newRun: Run?
    if let parser = GpxParser(url: url) {
      let parseResult = parser.parse()
      newRun = RunModel.addRun(parseResult.locations, autoName: parseResult.autoName, customName: parseResult.customName, timestamp: parseResult.locations.last!.timestamp, weather: parseResult.weather, temperature: parseResult.temperature, weight: parseResult.weight)
    }
    else {
      succeeded = false
    }
    if newRun == nil {
      succeeded = false
    }
    var resultMessage = ""
    if succeeded {
      if newRun?.customName == Run.noAutoName {
        resultMessage = RunModel.importSucceededMessage + "."
      }
      else {
        resultMessage = RunModel.importSucceededMessage + " " + ((newRun?.displayName())! as String) + "."
      }
      runModel.importedRunDelegate?.runWasImported()
    }
    else {
      resultMessage = RunModel.importFailedMessage
    }
    UIAlertController.showMessage(resultMessage, title: RunModel.importRunTitle)
    return succeeded
  }
  
  private class func addRun(coordinates: [CLLocation], customName: String, autoName: String, timestamp: NSDate, weather: String, temperature: Float, distance: Double, maxAltitude: Double, minAltitude: Double, maxLongitude: Double, minLongitude: Double, maxLatitude: Double, minLatitude: Double, altitudeGained: Double, altitudeLost: Double, weight: Double) -> Run {
    let newRun: Run = NSEntityDescription.insertNewObjectForEntityForName("Run", inManagedObjectContext: CDManager.sharedCDManager.context) as! Run
    newRun.distance = distance
    newRun.duration = coordinates[coordinates.count - 1].timestamp.timeIntervalSinceDate(coordinates[0].timestamp)
    newRun.timestamp = timestamp
    newRun.weather = weather
    newRun.temperature = temperature
    newRun.customName = customName
    newRun.autoName = autoName
    newRun.maxAltitude = maxAltitude
    newRun.minAltitude = minAltitude
    newRun.maxLatitude = maxLatitude
    newRun.minLatitude = minLatitude
    newRun.maxLongitude = maxLongitude
    newRun.minLongitude = minLongitude
    newRun.altitudeGained = altitudeGained
    newRun.altitudeLost = altitudeLost
    newRun.weight = weight
    var locationArray: [Location] = []
    for location in coordinates {
      let locationObject: Location = NSEntityDescription.insertNewObjectForEntityForName("Location", inManagedObjectContext: CDManager.sharedCDManager.context) as! Location
      locationObject.timestamp = location.timestamp
      locationObject.latitude = location.coordinate.latitude
      locationObject.longitude = location.coordinate.longitude
      locationObject.altitude = location.altitude
      locationArray.append(locationObject)
    }
    newRun.locations = NSOrderedSet(array: locationArray)
    CDManager.saveContext()
    return newRun
  }
  
  class func addRun(coordinates: [CLLocation], autoName: String, customName: String, timestamp: NSDate, weather: String, temperature: Float, weight: Double) -> Run {
    var distance = 0.0
    var altGained  = 0.0
    var altLost = 0.0
    var minLong = coordinates[0].coordinate.longitude
    var maxLong = coordinates[0].coordinate.longitude
    var minLat = coordinates[0].coordinate.latitude
    var maxLat = coordinates[0].coordinate.latitude
    var minAlt = coordinates[0].altitude
    var maxAlt = coordinates[0].altitude
    var curAlt = coordinates[0].altitude
    var currentCoordinate = coordinates[0]
    for var i = 1; i < coordinates.count; i++ {
      distance += coordinates[i].distanceFromLocation(currentCoordinate)
      currentCoordinate = coordinates[i]
      if currentCoordinate.coordinate.latitude < minLat {
        minLat = currentCoordinate.coordinate.latitude
      }
      if currentCoordinate.coordinate.longitude < minLong {
        minLong = currentCoordinate.coordinate.longitude
      }
      if currentCoordinate.coordinate.latitude > maxLat {
        maxLat = currentCoordinate.coordinate.latitude
      }
      if currentCoordinate.coordinate.longitude > maxLong {
        maxLong = currentCoordinate.coordinate.longitude
      }
      if currentCoordinate.altitude < minAlt {
        minAlt = currentCoordinate.altitude
      }
      if currentCoordinate.altitude > maxAlt {
        maxAlt = currentCoordinate.altitude
      }
      if currentCoordinate.altitude > curAlt + RunModel.altFudge {
        altGained += currentCoordinate.altitude - curAlt
      }
      if currentCoordinate.altitude < curAlt - RunModel.altFudge {
        altLost += curAlt - currentCoordinate.altitude
      }
      curAlt = coordinates[i].altitude
    }
    return RunModel.addRun(coordinates, customName: customName, autoName: autoName, timestamp: timestamp, weather: weather, temperature: temperature, distance: distance, maxAltitude: maxAlt, minAltitude: minAlt, maxLongitude: maxLong, minLongitude: minLong, maxLatitude: maxLat, minLatitude: minLat, altitudeGained: altGained, altitudeLost: altLost, weight: weight)
  }
  
  func stop() {
    timer.invalidate()
    locationManager.stopUpdatingLocation()
    if realRunInProgress && SettingsManager.getBroadcastNextRun() {
      PubNubManager.runStopped()
      PubNubManager.unsubscribeFromChannel(SettingsManager.getBroadcastName())
      SettingsManager.setBroadcastNextRun(false)
    }
    if runToSimulate == nil && gpxFile == nil {
      realRunInProgress = false
    }
    if runToSimulate == nil && gpxFile == nil && totalDistance > RunModel.minDistance {
      var customName = ""
      let fetchRequest = NSFetchRequest()
      let context = CDManager.sharedCDManager.context
      fetchRequest.entity = NSEntityDescription.entityForName("Run", inManagedObjectContext: context)
      let pastRuns = (try! context.executeFetchRequest(fetchRequest)) as! [Run]
      for pastRun in pastRuns {
        if pastRun.customName != "" {
          if (!RunModel.matchMeasurement(pastRun.distance.doubleValue, measurement2: totalDistance, tolerance: RunModel.distanceTolerance)) ||
              (!RunModel.matchMeasurement(pastRun.maxLatitude.doubleValue, measurement2: maxLat, tolerance: RunModel.coordinateTolerance)) ||
              (!RunModel.matchMeasurement(pastRun.minLatitude.doubleValue, measurement2: minLat, tolerance: RunModel.coordinateTolerance)) ||
              (!RunModel.matchMeasurement(pastRun.maxLongitude.doubleValue, measurement2: maxLong, tolerance: RunModel.coordinateTolerance)) ||
              (!RunModel.matchMeasurement(pastRun.minLongitude.doubleValue, measurement2: minLong, tolerance: RunModel.coordinateTolerance)) {
            continue
          }
          customName = pastRun.customName as String
          break
        }
      }
      run = RunModel.addRun(locations, customName: customName, autoName: autoName, timestamp: NSDate(), weather: weather, temperature: temperature, distance: totalDistance, maxAltitude: maxAlt, minAltitude: minAlt, maxLongitude: maxLong, minLongitude: minLong, maxLatitude: maxLat, minLatitude: minLat, altitudeGained: altGained, altitudeLost: altLost, weight: SettingsManager.getWeight())
      let result = Shoes.addMeters(totalDistance)
      if result != Shoes.shoesAreOkay {
        let delay = dispatch_time(dispatch_time_t(DISPATCH_TIME_NOW), UiConstants.messageDelay * Int64(NSEC_PER_SEC))
        dispatch_after(delay, dispatch_get_main_queue()) {
          UIAlertController.showMessage(result, title: Shoes.warningTitle, okTitle: Shoes.gotIt)
        }
      }
      if spectatorStoppedRun {
        runDelegate?.stopRun()
        spectatorStoppedRun = false
      }
    }
    else {
      // I don't consider this a magic number because the unadjusted length of a second will never change.
      secondLength = 1.0
      locationManager.kill()
      locationManager = nil
    }
    totalSeconds = 0
    totalDistance = 0.0
    currentSplitDistance = 0.0
    status = .PreRun
    locations = []
    didSetAutoNameAndFirstLoc = false
    altGained  = 0.0
    altLost = 0.0
    minLong = 0.0
    maxLong = 0.0
    minLat = 0.0
    maxLat = 0.0
    minAlt = 0.0
    maxAlt = 0.0
    sortedAltitudes = []
    sortedPaces = []
  }
  
  func pause() {
    status = .Paused
    timer.invalidate()
    locationManager.stopUpdatingLocation()
  }
  
  func resume() {
    status = .InProgress
    locationManager.startUpdatingLocation()
    startTimer()
  }
  
  func startTimer() {
    timer = NSTimer.scheduledTimerWithTimeInterval(secondLength, target: self, selector: Selector("eachSecond"), userInfo: nil, repeats: true)
  }
  
  class func matchMeasurement(measurement1: Double, measurement2: Double, tolerance: Double) -> Bool {
    let diff = fabs(measurement2 - measurement1)
    if (diff / measurement2) > tolerance {
      return false
    }
    else {
      return true
    }
  }
  
  func stopRun() {
    spectatorStoppedRun = true
    stop()
  }
  
  func receiveMessage(message: String) {
    Utterer.utter(message)
  }
}


