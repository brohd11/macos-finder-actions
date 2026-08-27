import Foundation
import FinderActionsCore

guard let machServiceName = RuntimeConfiguration.machServiceName() else {
    FileHandle.standardError.write(Data("Finder Actions Runner: missing Mach service configuration.\n".utf8))
    exit(78)
}

let catalog = CatalogCoordinator(configRoot: FinderActionConstants.configRoot)
let logStore = RunLogStore(directory: FinderActionConstants.runLogDirectory)
let service = RunnerService(
    machServiceName: machServiceName,
    catalog: catalog,
    executor: ScriptExecutor(logStore: logStore),
    logStore: logStore
)
service.resume()
RunLoop.main.run()
