import AutopilotAgent
import SwiftUI

struct ContentView: View {
    private let toolNames = AgentTool.allCases.map(\.rawValue)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mac Autopilot")
                .font(.headline)

            ForEach(toolNames, id: \.self) { toolName in
                Text(toolName)
                    .font(.system(.body, design: .monospaced))
            }
        }
        .padding()
        .frame(minWidth: 320, minHeight: 240)
    }
}

#Preview {
    ContentView()
}
