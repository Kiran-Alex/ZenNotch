//
//  MCPProtocol.swift
//  ZenNotch
//
//  The Model Context Protocol layer: JSON-RPC 2.0 requests in, results out. Knows the
//  tools (create/update/search/complete/delete tasks) and the todo:// resources.
//  Transport (HTTP, stdio) lives elsewhere; this only turns one message into one reply.
//

import Defaults
import Foundation

@MainActor
enum MCPProtocol {
    static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    static let instructions = """
        ZenNotch's task list, backed by Apple Reminders. Read todo://today or todo://active \
        to see what's on the user's plate, or use search_tasks to filter. Every task has an id; \
        pass it to update_task, complete_task or delete_task. Dates are ISO 8601 \
        (2026-11-17 or 2026-11-17T16:00) or plain English ("tomorrow 4pm"). Reminders has no \
        subtasks or tags, so ZenNotch keeps subtasks as a "- [ ]" checklist and tags as #hashtags \
        in the task's notes.
        """

    // MARK: Entry point

    /// Returns the JSON-RPC reply, or nil for notifications (which get no reply).
    static func handle(_ message: [String: Any]) async -> [String: Any]? {
        guard let method = message["method"] as? String else { return nil }   // a response from the client
        guard let id = message["id"], !(id is NSNull) else { return nil }     // a notification
        let params = message["params"] as? [String: Any] ?? [:]
        do {
            let result = try await dispatch(method, params)
            return ["jsonrpc": "2.0", "id": id, "result": result]
        } catch let e as RPCError {
            return ["jsonrpc": "2.0", "id": id, "error": ["code": e.code, "message": e.message]]
        } catch {
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32603, "message": error.localizedDescription]]
        }
    }

    struct RPCError: Error {
        let code: Int
        let message: String
        static func invalidParams(_ m: String) -> RPCError { .init(code: -32602, message: m) }
        static func notFound(_ m: String) -> RPCError { .init(code: -32601, message: m) }
    }

    private static func dispatch(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            return [
                "protocolVersion": supportedVersions.contains(asked) ? asked : supportedVersions[0],
                "capabilities": [
                    "tools": ["listChanged": false],
                    "resources": ["subscribe": false, "listChanged": false],
                ],
                "serverInfo": ["name": "zennotch", "title": "ZenNotch", "version": appVersion],
                "instructions": instructions,
            ]
        case "ping":
            return [:]
        case "tools/list":
            return ["tools": tools]
        case "tools/call":
            guard let name = params["name"] as? String else { throw RPCError.invalidParams("Missing tool name.") }
            return await callTool(name, params["arguments"] as? [String: Any] ?? [:])
        case "resources/list":
            return ["resources": resources]
        case "resources/templates/list":
            return ["resourceTemplates": [] as [Any]]
        case "resources/read":
            guard let uri = params["uri"] as? String else { throw RPCError.invalidParams("Missing uri.") }
            return try await readResource(uri)
        default:
            throw RPCError.notFound("Method not found: \(method)")
        }
    }

    // MARK: Tools

    private static func callTool(_ name: String, _ args: [String: Any]) async -> [String: Any] {
        let tasks = TasksManager.shared
        do {
            let result: [String: Any]
            switch name {
            case "create_task": result = try tasks.mcpCreate(args)
            case "update_task": result = try tasks.mcpUpdate(args)
            case "batch_update_tasks": result = try tasks.mcpBatchUpdate(args)
            case "complete_task": result = try tasks.mcpComplete(args)
            case "delete_task": result = try tasks.mcpDelete(args)
            case "search_tasks": result = try await tasks.mcpSearch(args)
            case "list_lists": result = try tasks.mcpListLists()
            default: return toolResult("Unknown tool: \(name)", isError: true)
            }
            return toolResult(json(result), isError: false)
        } catch let e as MCPToolError {
            return toolResult(e.message, isError: true)
        } catch {
            return toolResult(error.localizedDescription, isError: true)
        }
    }

    private static func toolResult(_ text: String, isError: Bool) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": isError]
    }

    private static func json(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    // MARK: Tool definitions

    private static func str(_ d: String) -> [String: Any] { ["type": "string", "description": d] }
    private static func strArray(_ d: String) -> [String: Any] {
        ["type": "array", "items": ["type": "string"], "description": d]
    }
    private static func num(_ d: String) -> [String: Any] { ["type": "integer", "description": d] }
    private static func flag(_ d: String) -> [String: Any] { ["type": "boolean", "description": d] }
    private static func object(_ props: [String: Any], required: [String] = []) -> [String: Any] {
        var o: [String: Any] = ["type": "object", "properties": props]
        if !required.isEmpty { o["required"] = required }
        return o
    }
    private static func hints(readOnly: Bool = false, destructive: Bool = false, idempotent: Bool = false) -> [String: Any] {
        ["readOnlyHint": readOnly, "destructiveHint": destructive, "idempotentHint": idempotent, "openWorldHint": false]
    }

    private static let dueHelp = "ISO 8601 (\"2026-11-17\" for a date only, \"2026-11-17T16:00\" with a time, local time unless an offset is given) or plain English (\"tomorrow 4pm\")."
    private static let priorityHelp = "none, low, medium or high."

    /// Fields shared by update_task and each entry of batch_update_tasks.
    private static var patchProps: [String: Any] {
        [
            "title": str("New title."),
            "notes": str("Replaces the notes (markdown). null clears them. Subtask checklist and tags live in the notes."),
            "due": str("New due date. \(dueHelp) null or \"\" removes the due date."),
            "shift_days": num("Move the existing due date by this many days (negative = earlier), keeping its time. Handy for rescheduling."),
            "priority": str(priorityHelp),
            "list": str("Move to this list (name or id)."),
            "completed": flag("true marks it done, false reopens it."),
            "tags": strArray("Replaces the task's tags (written as #hashtags in the notes). [] removes them."),
            "add_subtasks": strArray("Subtasks to add to the checklist in the notes."),
            "duration_minutes": num("Planned focus time in minutes (shown in the notch). null clears it."),
        ]
    }

    static var tools: [[String: Any]] {
        var update = patchProps
        update["id"] = str("The task's id.")
        var batchItem = patchProps
        batchItem["id"] = str("The task's id.")

        return [
            [
                "name": "create_task",
                "title": "Create task",
                "description": "Add a task to Apple Reminders (shows in the ZenNotch Tasks card). One call can set notes, due date, priority, list, tags and subtasks.",
                "inputSchema": object([
                    "title": str("What needs doing."),
                    "notes": str("Details, in markdown."),
                    "due": str("Due date. \(dueHelp) Omit for no due date."),
                    "priority": str(priorityHelp),
                    "list": str("Reminders list name or id. Defaults to the user's default list."),
                    "tags": strArray("Tags, with or without #. Stored as #hashtags in the notes."),
                    "subtasks": strArray("Subtask titles. Stored as a \"- [ ]\" checklist in the notes."),
                    "duration_minutes": num("Planned focus time in minutes."),
                ], required: ["title"]),
                "annotations": hints(),
            ],
            [
                "name": "update_task",
                "title": "Update task",
                "description": "Change any fields of one task. Only the fields you pass change.",
                "inputSchema": object(update, required: ["id"]),
                "annotations": hints(idempotent: true),
            ],
            [
                "name": "batch_update_tasks",
                "title": "Update many tasks",
                "description": "Apply changes to several tasks in one call, e.g. reschedule everything overdue with shift_days or a new due date. Each update succeeds or fails on its own.",
                "inputSchema": object([
                    "updates": [
                        "type": "array", "maxItems": 100,
                        "description": "One entry per task: its id plus the fields to change.",
                        "items": object(batchItem, required: ["id"]),
                    ] as [String: Any],
                ], required: ["updates"]),
                "annotations": hints(idempotent: true),
            ],
            [
                "name": "complete_task",
                "title": "Complete tasks",
                "description": "Mark one or more tasks done (or reopen them with completed=false).",
                "inputSchema": object([
                    "id": str("A task id."),
                    "ids": strArray("Several task ids."),
                    "completed": flag("Default true. false reopens the tasks."),
                ]),
                "annotations": hints(idempotent: true),
            ],
            [
                "name": "delete_task",
                "title": "Delete tasks",
                "description": "Permanently delete tasks from Reminders. This can't be undone. Off unless the user allows it in ZenNotch settings. Prefer complete_task for finished work.",
                "inputSchema": object([
                    "id": str("A task id."),
                    "ids": strArray("Several task ids."),
                ]),
                "annotations": hints(destructive: true, idempotent: true),
            ],
            [
                "name": "search_tasks",
                "title": "Search tasks",
                "description": "Find tasks. Open tasks by default, soonest due first. Combine any filters. For \"what's on my plate\" you can also read todo://today.",
                "inputSchema": object([
                    "query": str("Text to look for in the title, notes or list name."),
                    "status": ["type": "string", "enum": ["open", "completed", "all"],
                               "description": "Default open. Completed covers the last year."] as [String: Any],
                    "due_from": str("Due on or after this day. \(dueHelp)"),
                    "due_to": str("Due on or before this day. \(dueHelp)"),
                    "overdue": flag("Only open tasks past their due date or time."),
                    "no_due_date": flag("Only tasks without a due date."),
                    "min_priority": str("At least this priority: low, medium or high."),
                    "list": str("Only this list (name or id)."),
                    "tag": str("Only tasks with this #tag."),
                    "limit": num("Max tasks to return (default 50, max 200)."),
                ]),
                "annotations": hints(readOnly: true, idempotent: true),
            ],
            [
                "name": "list_lists",
                "title": "List Reminders lists",
                "description": "The user's Reminders lists, to use as the list argument.",
                "inputSchema": object([:]),
                "annotations": hints(readOnly: true, idempotent: true),
            ],
        ]
    }

    // MARK: Resources

    private static let resourceTable: [(uri: String, name: String, title: String, description: String)] = [
        ("todo://today", "today", "Today",
         "Tasks that are overdue or due today. Read this to know what's on the user's plate right now."),
        ("todo://active", "active", "All open tasks",
         "Every open task, grouped into overdue, today, upcoming and no due date."),
        ("todo://overdue", "overdue", "Overdue tasks", "Open tasks past their due date."),
    ]

    static var resources: [[String: Any]] {
        resourceTable.map {
            ["uri": $0.uri, "name": $0.name, "title": $0.title, "description": $0.description,
             "mimeType": "text/markdown"]
        }
    }

    private static func readResource(_ uri: String) async throws -> [String: Any] {
        guard let entry = resourceTable.first(where: { $0.uri == uri }) else {
            throw RPCError(code: -32002, message: "Resource not found: \(uri)")
        }
        let text: String
        do { text = try await TasksManager.shared.mcpMarkdown(scope: entry.name) }
        catch let e as MCPToolError { throw RPCError(code: -32603, message: e.message) }
        return ["contents": [["uri": uri, "mimeType": "text/markdown", "text": text]]]
    }
}
