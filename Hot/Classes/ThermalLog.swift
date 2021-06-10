/*******************************************************************************
 * The MIT License (MIT)
 * 
 * Copyright (c) 2020 Jean-David Gadina - www.xs-labs.com
 * 
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 * 
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 * 
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 ******************************************************************************/

import Foundation
import Cocoa

let SMC_CPU_CORE_TEMP_NEW = "TC%@c"

func gCPUPackageCount() -> Int {
  var c: Int = 0
  var l: size_t = MemoryLayout<Int>.size
  sysctlbyname("hw.packages", &c, &l, nil, 0)
  return c
}

func gCountPhisycalCores() -> Int {
  var c: Int = 0
  var l: size_t = MemoryLayout<Int>.size
  sysctlbyname("machdep.cpu.core_count", &c, &l, nil, 0)
  return c
}

func smcFormat(_ num: Int) -> String {
  if num > 15 {
    let GZ = (0..<20).map({Character(UnicodeScalar("G".unicodeScalars.first!.value + $0)!)})
    for c in GZ {
      let i = Int(c.unicodeScalars.first!.value) - 55
      if i == num {
        return "\(c)"
      }
    }
  }
  return String(format: "%.1X", num)
}

// Thanks to Airspeed Velocity for the great idea!
// http://airspeedvelocity.net/2015/05/22/my-talk-at-swift-summit/
public extension FourCharCode {
  init(fromString str: String) {
    precondition(str.count == 4)
    
    self = str.utf8.reduce(0) { sum, character in
      return sum << 8 | UInt32(character)
    }
  }
  
  init(fromStaticString str: StaticString) {
    precondition(str.utf8CodeUnitCount == 4)
    
    self = str.withUTF8Buffer { buffer in
      // TODO: Broken up due to "Expression was too complex" error as of
      //       Swift 4.
      let byte0 = UInt32(buffer[0]) << 24
      let byte1 = UInt32(buffer[1]) << 16
      let byte2 = UInt32(buffer[2]) << 8
      let byte3 = UInt32(buffer[3])
      
      return byte0 | byte1 | byte2 | byte3
    }
  }
  
  func toString() -> String {
    return "\(String(describing: UnicodeScalar(self >> 24 & 0xff)!))\(String(describing: UnicodeScalar(self >> 16 & 0xff)!))\(String(describing: UnicodeScalar(self >> 8  & 0xff)!))\(String(describing: UnicodeScalar(self       & 0xff)!))"
    /*
    return String(describing: UnicodeScalar(self >> 24 & 0xff)!) +
      String(describing: UnicodeScalar(self >> 16 & 0xff)!) +
      String(describing: UnicodeScalar(self >> 8  & 0xff)!) +
      String(describing: UnicodeScalar(self       & 0xff)!)*/
  }
}

// MARK:

public class ThermalLog: NSObject
{
    @objc public dynamic var schedulerLimit: NSNumber?
    @objc public dynamic var availableCPUs:  NSNumber?
    @objc public dynamic var speedLimit:     NSNumber?
    @objc public dynamic var cpuTemperature: NSNumber?
    @objc public dynamic var sensors:        [ String : Double ] = [:]
    
    private var refreshing = false
    
    private static var queue = DispatchQueue( label: "com.xs-labs.Hot.ThermalLog", qos: .background, attributes: [], autoreleaseFrequency: .workItem, target: nil )
    
    public override init()
    {
        super.init()
        self.refresh()
    }
    
    private func readSensors() -> [ String : Double ]
    {
        #if arch( arm64 )
        
        Dictionary( uniqueKeysWithValues:
            ReadM1Sensors().filter
            {
                $0.key.hasPrefix( "pACC" ) || $0.key.hasPrefix( "eACC" )
            }
            .map
            {
                ( $0.key, $0.value.doubleValue )
            }
        )
        
        #else
        
        let cpuCount = gCountPhisycalCores() * gCPUPackageCount()
        var result = [ String : Double ]()
        for i in 0..<cpuCount {
            let key = String(format: SMC_CPU_CORE_TEMP_NEW, smcFormat(i))
            let title = String(format: "CPU %02d", i)
            result[title] = SMCGetTemperature(FourCharCode.init(fromString: key))
        }
        
        return result

        #endif
    }
    
    public func refresh()
    {
        ThermalLog.queue.async
        {
            if self.refreshing
            {
                return
            }
            
            self.refreshing = true
            
            let sensors = self.readSensors()
            let temp    = SMCGetCPUTemperature()
            
            if temp > 1
            {
                DispatchQueue.main.async
                {
                    self.sensors        = sensors
                    self.cpuTemperature = NSNumber( value: temp )
                }
            }
            
            let pipe            = Pipe()
            let task            = Process()
            task.launchPath     = "/usr/bin/pmset"
            task.arguments      = [ "-g", "therm" ]
            task.standardOutput = pipe
            
            task.launch()
            task.waitUntilExit()
            
            if task.terminationStatus != 0
            {
                self.refreshing = false
                
                return
            }
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            
            guard let str = String( data: data, encoding: .utf8 ), str.count > 0 else
            {
                self.refreshing = false
                
                return
            }
            
            let lines = str.replacingOccurrences( of: " ",  with: "" ).replacingOccurrences( of: "\t", with: "" ).split( separator: "\n" )
            
            for line in lines
            {
                let p = line.split( separator: "=" )
                
                if p.count < 2
                {
                    continue
                }
                
                guard let n = UInt( p[ 1 ] ) else
                {
                    continue
                }
                
                if( p[ 0 ] == "CPU_Scheduler_Limit" )
                {
                    DispatchQueue.main.async { self.schedulerLimit = NSNumber( value: n ) }
                }
                else if( p[ 0 ] == "CPU_Available_CPUs" )
                {
                    DispatchQueue.main.async { self.availableCPUs = NSNumber( value: n ) }
                }
                else if( p[ 0 ] == "CPU_Speed_Limit" )
                {
                    DispatchQueue.main.async { self.speedLimit = NSNumber( value: n ) }
                }
            }
            
            self.refreshing = false
        }
    }
}
