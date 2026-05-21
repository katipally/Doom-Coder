//
//  DoomCoderWidgetBundle.swift
//  DoomCoderWidget
//
//  Created by Yash on 5/21/26.
//

import WidgetKit
import SwiftUI

@main
struct DoomCoderWidgetBundle: WidgetBundle {
    var body: some Widget {
        DoomCoderWidget()
        DoomCoderWidgetControl()
        DoomCoderWidgetLiveActivity()
    }
}
