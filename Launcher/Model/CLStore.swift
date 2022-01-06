//
//  CLStore.swift
//  launcher
//
//  Created by Kai on 11/18/21.
//

import Cocoa
import Combine
import Foundation
import SwiftUI

class CLStore: ObservableObject {
    static let shared: CLStore = .init()

    var envSHELL: String = ""
    var envPATH: String = ""

    @Published var currentViewingTaskID: UUID?

    @Published var projects: [CLProject] = [] {
        didSet {
            DispatchQueue.global(qos: .background).async {
                self._saveTasks()
            }
            if let uuidString = UserDefaults.standard.object(forKey: String.lastActiveProjectUUIDKey) as? String, let uuid = UUID(uuidString: uuidString) {
                DispatchQueue.main.async {
                    CLStore.shared.currentProjectID = uuid
                }
            }
        }
    }

    @Published var currentProjectID: UUID = .init() {
        didSet {
            UserDefaults.standard.set(currentProjectID.uuidString, forKey: String.lastActiveProjectUUIDKey)

            let lastSelectedTaskIndexKey = currentProjectID.uuidString + "-" + String.lastSelectedTaskIndexKey
            if UserDefaults.standard.value(forKey: lastSelectedTaskIndexKey) == nil {
                selectedTaskIndex = -1
            } else {
                selectedTaskIndex = UserDefaults.standard.integer(forKey: lastSelectedTaskIndexKey)
            }

            let minTaskViewHeight: CGFloat = 84
            let lastSelectedProjectConsoleTaskViewHeightKey = currentProjectID.uuidString + "-" + String.lastActiveConsoleTaskViewHeightKey
            let lastActiveTaskViewHeight: CGFloat = .init(UserDefaults.standard.float(forKey: lastSelectedProjectConsoleTaskViewHeightKey))

            if lastActiveTaskViewHeight > 0 {
                outputTaskViewHeight = lastActiveTaskViewHeight
            } else {
                if let p = loadProject(byID: currentProjectID) {
                    if p.tasks.count > 3 {
                        outputTaskViewHeight = minTaskViewHeight * 3
                    } else if p.tasks.count == 0 {
                        outputTaskViewHeight = minTaskViewHeight
                    } else {
                        outputTaskViewHeight = minTaskViewHeight * CGFloat(p.tasks.count)
                    }
                } else {
                    outputTaskViewHeight = minTaskViewHeight
                }
            }

            let lastSelectedProjectConsoleStatusKey = currentProjectID.uuidString + "-" + String.lastSelectedProjectConsoleStatusKey
            outputConsoleClosed = UserDefaults.standard.bool(forKey: lastSelectedProjectConsoleStatusKey)

            NotificationCenter.default.post(name: .scrollDownToLatestConsoleOutput, object: nil)
        }
    }

    @Published var taskProcesses: [String: Process] = [:] {
        didSet {
            DispatchQueue.global(qos: .utility).async {
                self._updateExistingTasks()
            }

            DispatchQueue.global(qos: .background).async {
                var updatedActiveProjects: [String] = []
                for taskID in self.taskProcesses.keys {
                    for p in self.projects {
                        for t in p.tasks {
                            if taskID == t.id.uuidString {
                                if !updatedActiveProjects.contains(p.id.uuidString) {
                                    updatedActiveProjects.append(p.id.uuidString)
                                }
                            }
                        }
                    }
                }
                DispatchQueue.main.async {
                    self.activeProjects = updatedActiveProjects
                }
            }
        }
    }

    @Published var activeProjects: [String] = []
    @Published var projectOutputs: [CLTaskOutput] = [] {
        didSet {
            DispatchQueue.global(qos: .background).async {
                guard let last = self.projectOutputs.last, last.projectID == self.currentProjectID else { return }
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .scrollDownToLatestConsoleOutput, object: last)
                }
            }
        }
    }

    @Published var selectedTaskIndex: Int = -1 {
        didSet {
            let lastSelectedTaskIndexKey = currentProjectID.uuidString + "-" + String.lastSelectedTaskIndexKey
            UserDefaults.standard.set(selectedTaskIndex, forKey: lastSelectedTaskIndexKey)
        }
    }

    @Published var outputConsoleClosed: Bool = false {
        didSet {
            let lastSelectedProjectConsoleStatusKey = currentProjectID.uuidString + "-" + String.lastSelectedProjectConsoleStatusKey
            UserDefaults.standard.set(outputConsoleClosed, forKey: lastSelectedProjectConsoleStatusKey)
        }
    }

    @Published var outputTaskViewHeight: CGFloat = 84

    @Published var retriedTasks: [String: Int] = [:]
    @Published var editingProject: CLProject!

    @Published var isAlert: Bool = false
    @Published var alertTitle: String = ""
    @Published var alertMessage: String = ""

    @Published var isEditingProject: Bool = false
    @Published var isDeletingProject: Bool = false
    @Published var isImportingProject: Bool = false

    init() {
        debugPrint("CL Store Init.")
        let p = _loadTasks().sorted { a, b in
            a.created > b.created
        }
        DispatchQueue.main.async {
            self.projects = p
            DispatchQueue.global(qos: .utility).async {
                self._detectExistingTasks()
            }
        }
    }

    func loadProject(byID id: UUID) -> CLProject? {
        projects.filter { t in
            t.id == id
        }.first
    }

    func saveProject(project: CLProject) {
        projects = projects.map { p in
            if p.id == project.id {
                return project
            }
            return p
        }
        DispatchQueue.global(qos: .background).async {
            self._saveTasks()
        }
        if let img = CLTaskManager.shared.projectAvatar(projectID: editingProject.id, isEditing: true) {
            CLTaskManager.shared.updateProjectAvatar(image: img)
            CLTaskManager.shared.removeProjectAvatar(projectID: editingProject.id, isEditing: true)
        }
        NotificationCenter.default.post(name: .updateProjectAvatar, object: nil)
    }

    private func _saveTasks() {
        let databasePath = CLTaskManager.shared.databasePath()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        do {
            let data = try encoder.encode(projects)
            try data.write(to: databasePath, options: .atomic)
        } catch {
            debugPrint("failed to save tasks: \(error)")
        }
    }

    private func _loadTasks() -> [CLProject] {
        let databasePath = CLTaskManager.shared.databasePath()
        let decoder = JSONDecoder()
        do {
            let data = try Data(contentsOf: databasePath)
            return try decoder.decode([CLProject].self, from: data)
        } catch {
            debugPrint("failed to load tasks: \(error), try to reset to default.")
            if FileManager.default.fileExists(atPath: databasePath.path) {
                try? FileManager.default.removeItem(at: databasePath)
                DispatchQueue.global(qos: .utility).async {
                    DispatchQueue.main.async {
                        self.projects = self._loadTasks().sorted { a, b in
                            a.created > b.created
                        }
                    }
                }
            }
        }
        return []
    }

    private func _detectExistingTasks() {
        let taskPath = CLTaskManager.shared.taskPath()
        let decoder = JSONDecoder()
        do {
            let data = try Data(contentsOf: taskPath)
            let taskPIDs: [CLTaskPID] = try decoder.decode([CLTaskPID].self, from: data)
            for taskPID in taskPIDs {
                let cmd = CLCommand(executable: URL(fileURLWithPath: "/bin/kill"), directory: URL(fileURLWithPath: ""), arguments: ["-9", "\(taskPID.identifier)"])
                runAsyncCommand(command: cmd) { _, _, _ in
                }
            }
        } catch {
            debugPrint("failed to load task pids: \(error)")
        }
    }

    private func _updateExistingTasks() {
        let taskPath = CLTaskManager.shared.taskPath()
        var taskPIDs: [CLTaskPID] = []
        for uuid in taskProcesses.keys {
            guard let p = taskProcesses[uuid], let id = UUID(uuidString: uuid) else { continue }
            taskPIDs.append(CLTaskPID(id: id, identifier: p.processIdentifier))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        do {
            let data = try encoder.encode(taskPIDs)
            try data.write(to: taskPath, options: .atomic)
        } catch {
            debugPrint("failed to update task pids: \(error)")
        }
    }
}