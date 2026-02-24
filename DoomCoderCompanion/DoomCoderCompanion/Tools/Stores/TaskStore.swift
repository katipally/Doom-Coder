// TaskStore.swift — DoomCoder Companion (Tools)
// On-device store for the Tasks checklist ("things to hand your agent"). Local.

import Foundation
import Observation

@MainActor
@Observable
final class TaskStore {
    static let shared = TaskStore()

    private let fileName = "tasks.json"
    private(set) var tasks: [AgentTask] = []

    private init() {
        tasks = JSONFileStore.load([AgentTask].self, from: fileName) ?? []
    }

    var openCount: Int { tasks.filter { !$0.isDone }.count }

    func add(_ task: AgentTask) {
        tasks.insert(task, at: 0)
        persist()
    }

    func update(_ task: AgentTask) {
        guard let idx = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[idx] = task
        persist()
    }

    func toggle(_ task: AgentTask) {
        guard let idx = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[idx].isDone.toggle()
        persist()
    }

    func delete(_ task: AgentTask) {
        tasks.removeAll { $0.id == task.id }
        persist()
    }

    func delete(at offsets: IndexSet, in visible: [AgentTask]) {
        let ids = offsets.map { visible[$0].id }
        tasks.removeAll { ids.contains($0.id) }
        persist()
    }

    func move(from source: IndexSet, to destination: Int) {
        tasks.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    func clearCompleted() {
        tasks.removeAll { $0.isDone }
        persist()
    }

    func deleteAll() {
        tasks.removeAll()
        persist()
    }

    private func persist() {
        JSONFileStore.save(tasks, to: fileName)
    }
}
