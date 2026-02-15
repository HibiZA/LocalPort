import Foundation
import os.log

private let logger = Logger(subsystem: "com.devspace.app", category: "ProjectDetector")

/// The detected type of a project
enum ProjectType: String, Codable {
    case node         // package.json
    case nextjs       // package.json + next in dependencies
    case vite         // package.json + vite in dependencies
    case remix        // package.json + remix in dependencies
    case astro        // package.json + astro in dependencies
    case python       // requirements.txt or pyproject.toml
    case django       // manage.py
    case flask        // app.py with flask import
    case rust         // Cargo.toml
    case go           // go.mod
    case ruby         // Gemfile
    case rails        // Gemfile + bin/rails
    case php          // composer.json
    case laravel      // composer.json + artisan
    case elixir       // mix.exs
    case swift        // Package.swift
    case unknown
}

/// Information about a detected project
struct ProjectInfo {
    let type: ProjectType
    let name: String
    let devCommand: String?       // command to start the dev server
    let defaultPort: Int?         // expected port
    let readyPattern: String?     // regex to detect server ready in stdout
    let needsBrowser: Bool        // whether this project has a web UI
}

/// Scans a project directory to determine its type and how to run it
final class ProjectDetector {

    func detect(directory: String) -> ProjectInfo {
        let fm = FileManager.default
        let dir = directory

        func exists(_ file: String) -> Bool {
            fm.fileExists(atPath: (dir as NSString).appendingPathComponent(file))
        }

        func readFile(_ file: String) -> String? {
            let path = (dir as NSString).appendingPathComponent(file)
            return try? String(contentsOfFile: path, encoding: .utf8)
        }

        func readJSON(_ file: String) -> [String: Any]? {
            let path = (dir as NSString).appendingPathComponent(file)
            guard let data = fm.contents(atPath: path) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }

        let dirName = (dir as NSString).lastPathComponent

        // Check .devspace.toml for explicit dev command override
        if exists(".devspace.toml"), let tomlContent = readFile(".devspace.toml") {
            let command = extractTOMLValue(tomlContent, key: "command")
            if let command = command, !command.isEmpty {
                let name = extractTOMLValue(tomlContent, key: "name") ?? dirName
                let portStr = extractTOMLValue(tomlContent, key: "port")
                let port = portStr.flatMap { Int($0) }
                let needsBrowser = port != nil
                logger.info("Using .devspace.toml override: \(command)")
                return ProjectInfo(
                    type: .unknown, name: name,
                    devCommand: command,
                    defaultPort: port, readyPattern: nil,
                    needsBrowser: needsBrowser
                )
            }
        }

        // Node.js ecosystem
        if exists("package.json"), let pkg = readJSON("package.json") {
            let deps = mergeDeps(pkg)
            let scripts = pkg["scripts"] as? [String: String] ?? [:]
            let name = pkg["name"] as? String ?? dirName

            // Detect specific frameworks
            if deps.contains("next") {
                return ProjectInfo(
                    type: .nextjs, name: name,
                    devCommand: devCmd(scripts, prefer: ["dev"], fallback: "npx next dev", directory: dir),
                    defaultPort: 3000, readyPattern: "Ready in|ready on|started server",
                    needsBrowser: true
                )
            }
            if deps.contains("astro") {
                return ProjectInfo(
                    type: .astro, name: name,
                    devCommand: devCmd(scripts, prefer: ["dev"], fallback: "npx astro dev", directory: dir),
                    defaultPort: 4321, readyPattern: "astro.*started",
                    needsBrowser: true
                )
            }
            if deps.contains("@remix-run/dev") || deps.contains("remix") {
                return ProjectInfo(
                    type: .remix, name: name,
                    devCommand: devCmd(scripts, prefer: ["dev"], fallback: "npx remix dev", directory: dir),
                    defaultPort: 3000, readyPattern: "started",
                    needsBrowser: true
                )
            }
            if deps.contains("vite") {
                return ProjectInfo(
                    type: .vite, name: name,
                    devCommand: devCmd(scripts, prefer: ["dev"], fallback: "npx vite", directory: dir),
                    defaultPort: 5173, readyPattern: "ready in|Local:",
                    needsBrowser: true
                )
            }

            // Generic Node project
            let hasServer = deps.contains("express") || deps.contains("fastify") || deps.contains("koa") || deps.contains("hono")
            return ProjectInfo(
                type: .node, name: name,
                devCommand: devCmd(scripts, prefer: ["dev", "start"], fallback: nil, directory: dir),
                defaultPort: hasServer ? 3000 : nil,
                readyPattern: hasServer ? "listening|started" : nil,
                needsBrowser: hasServer
            )
        }

        // Rust
        if exists("Cargo.toml") {
            let cargoContent = readFile("Cargo.toml") ?? ""
            let name = extractTOMLValue(cargoContent, key: "name") ?? dirName
            let isWeb = cargoContent.contains("actix") || cargoContent.contains("axum")
                || cargoContent.contains("rocket") || cargoContent.contains("warp")
            return ProjectInfo(
                type: .rust, name: name,
                devCommand: isWeb ? "cargo run" : "cargo run",
                defaultPort: isWeb ? 8080 : nil,
                readyPattern: isWeb ? "listening|started|binding" : nil,
                needsBrowser: isWeb
            )
        }

        // Go
        if exists("go.mod") {
            let modContent = readFile("go.mod") ?? ""
            let name = modContent.components(separatedBy: "\n").first?
                .replacingOccurrences(of: "module ", with: "")
                .components(separatedBy: "/").last ?? dirName
            return ProjectInfo(
                type: .go, name: name,
                devCommand: "go run .",
                defaultPort: 8080, readyPattern: "listening|started",
                needsBrowser: true
            )
        }

        // Python
        if exists("manage.py") {
            return ProjectInfo(
                type: .django, name: dirName,
                devCommand: "python manage.py runserver",
                defaultPort: 8000, readyPattern: "Starting development server",
                needsBrowser: true
            )
        }
        if exists("pyproject.toml") || exists("requirements.txt") {
            let hasFastAPI = (readFile("requirements.txt") ?? "").contains("fastapi")
                || (readFile("pyproject.toml") ?? "").contains("fastapi")
            let hasFlask = (readFile("requirements.txt") ?? "").contains("flask")
                || exists("app.py")
            if hasFlask {
                return ProjectInfo(
                    type: .flask, name: dirName,
                    devCommand: "flask run",
                    defaultPort: 5000, readyPattern: "Running on",
                    needsBrowser: true
                )
            }
            if hasFastAPI {
                return ProjectInfo(
                    type: .python, name: dirName,
                    devCommand: "uvicorn main:app --reload",
                    defaultPort: 8000, readyPattern: "Uvicorn running",
                    needsBrowser: true
                )
            }
            return ProjectInfo(
                type: .python, name: dirName,
                devCommand: nil, defaultPort: nil, readyPattern: nil,
                needsBrowser: false
            )
        }

        // Ruby / Rails
        if exists("Gemfile") {
            if exists("bin/rails") {
                return ProjectInfo(
                    type: .rails, name: dirName,
                    devCommand: "bin/rails server",
                    defaultPort: 3000, readyPattern: "Listening on",
                    needsBrowser: true
                )
            }
            return ProjectInfo(
                type: .ruby, name: dirName,
                devCommand: nil, defaultPort: nil, readyPattern: nil,
                needsBrowser: false
            )
        }

        // PHP / Laravel
        if exists("composer.json") {
            if exists("artisan") {
                return ProjectInfo(
                    type: .laravel, name: dirName,
                    devCommand: "php artisan serve",
                    defaultPort: 8000, readyPattern: "started",
                    needsBrowser: true
                )
            }
            return ProjectInfo(
                type: .php, name: dirName,
                devCommand: nil, defaultPort: nil, readyPattern: nil,
                needsBrowser: false
            )
        }

        // Elixir
        if exists("mix.exs") {
            return ProjectInfo(
                type: .elixir, name: dirName,
                devCommand: "mix phx.server",
                defaultPort: 4000, readyPattern: "Running.*on",
                needsBrowser: true
            )
        }

        // Swift
        if exists("Package.swift") {
            return ProjectInfo(
                type: .swift, name: dirName,
                devCommand: "swift run",
                defaultPort: nil, readyPattern: nil,
                needsBrowser: false
            )
        }

        logger.info("Could not detect project type for \(directory)")
        return ProjectInfo(
            type: .unknown, name: dirName,
            devCommand: nil, defaultPort: nil, readyPattern: nil,
            needsBrowser: false
        )
    }

    // MARK: - Helpers

    /// Merge dependencies and devDependencies keys from package.json
    private func mergeDeps(_ pkg: [String: Any]) -> Set<String> {
        var all = Set<String>()
        if let deps = pkg["dependencies"] as? [String: Any] {
            all.formUnion(deps.keys)
        }
        if let devDeps = pkg["devDependencies"] as? [String: Any] {
            all.formUnion(devDeps.keys)
        }
        return all
    }

    /// Detect package manager from lockfiles in the project directory
    private func detectPackageManager(directory: String) -> (runner: String, exec: String) {
        let fm = FileManager.default
        func exists(_ file: String) -> Bool {
            fm.fileExists(atPath: (directory as NSString).appendingPathComponent(file))
        }

        if exists("bun.lockb") || exists("bun.lock") {
            return ("bun run", "bunx")
        }
        if exists("pnpm-lock.yaml") {
            return ("pnpm run", "pnpm dlx")
        }
        if exists("yarn.lock") {
            return ("yarn", "yarn dlx")
        }
        return ("npm run", "npx")
    }

    /// Pick the best dev command from package.json scripts
    private func devCmd(_ scripts: [String: String], prefer: [String],
                        fallback: String?, directory: String) -> String? {
        let pm = detectPackageManager(directory: directory)

        for key in prefer {
            if scripts[key] != nil {
                return "\(pm.runner) \(key)"
            }
        }

        // Rewrite npx fallbacks to use the detected executor
        if let fallback = fallback, fallback.hasPrefix("npx ") {
            return pm.exec + fallback.dropFirst(3)
        }
        return fallback
    }

    /// Simple TOML value extraction (name = "value")
    private func extractTOMLValue(_ content: String, key: String) -> String? {
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(key) && trimmed.contains("=") {
                let parts = trimmed.components(separatedBy: "=")
                if parts.count >= 2 {
                    return parts[1]
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                }
            }
        }
        return nil
    }
}
