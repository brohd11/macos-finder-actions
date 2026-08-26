import Foundation
import FinderActionsCore

guard
    let containerURL = RuntimeConfiguration.sharedContainerURL(),
    let machServiceName = RuntimeConfiguration.machServiceName()
else {
    FileHandle.standardError.write(Data("Finder Actions Runner: missing app-group configuration.\n".utf8))
    exit(78)
}

let catalog = CatalogCoordinator(configRoot: FinderActionConstants.configRoot, containerURL: containerURL)
let logStore = RunLogStore(directory: containerURL.appendingPathComponent(FinderActionConstants.runDirectoryName, isDirectory: true))
let service = RunnerService(
    machServiceName: machServiceName,
    catalog: catalog,
    executor: ScriptExecutor(logStore: logStore),
    logStore: logStore
)
service.resume()
RunLoop.main.run()
