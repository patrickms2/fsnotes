//
//  FileSystemEventManager.swift
//  FSNotes
//
//  Created by Oleksandr Glushchenko on 7/13/18.
//  Copyright © 2018 Oleksandr Glushchenko. All rights reserved.
//

import Foundation
import FSNotesCore_macOS

class FileSystemEventManager {
    private var storage: Storage
    private var delegate: ViewController
    private var watcher: FileWatcher?
    private var observedFolders: [String]
    
    init(storage: Storage, delegate: ViewController) {
        self.storage = storage
        self.delegate = delegate
        self.observedFolders = self.storage.getProjectPaths()
    }
    
    public func start() {
        watcher = FileWatcher(self.observedFolders)
        watcher?.callback = { event in
            if UserDataService.instance.fsUpdatesDisabled {
                return
            }
            
            guard let path = event.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
                return
            }
            
            guard let url = URL(string: "file://" + path) else {
                return
            }

            if !event.path.contains(".textbundle") && (
                    event.dirRemoved
                    || event.dirCreated
                    || event.dirRenamed
                    || event.dirChange
            ) {
                self.handleDirEvents(event: event)
                return
            }

            if !self.storage.allowedExtensions.contains(url.pathExtension) && !self.storage.isValidUTI(url: url) {
                return
            }
            
            if event.fileRemoved || event.dirRemoved {
                guard let note = self.storage.getBy(url: url) else { return }
                
                self.removeNote(note: note)
            }

            let fullUrl = self.handleTextBundle(url: url)

            // Resolve conflicts if exist
            if let note = self.storage.getBy(url: fullUrl) {
                self.resolveConflict(url: note.url)
            }

            if event.fileRenamed || event.dirRenamed {
                self.moveHandler(url: url, pathList: self.observedFolders)
                return
            }

            guard self.checkFile(url: fullUrl, pathList: self.observedFolders) else { return }

            // Order is important, invoke only before change
            if event.fileCreated {
                self.importNote(fullUrl)
                return
            }

            if event.fileChange || event.dirChange, let note = self.storage.getBy(url: fullUrl) {
                self.reloadNote(note: note)
            }
        }
        
        watcher?.start()
    }

    private func handleDirEvents(event: FileWatcherEvent) {
        guard !event.path.contains("Trash") else { return }

        let dirURL = URL(fileURLWithPath: event.path, isDirectory: true)
        let project = self.storage.getProjectBy(url: dirURL)

        guard dirURL.lastPathComponent != ".git" else {
            return
        }
        
        guard !dirURL.isHidden() else {
            // hide if exist and hidden (xattr "es.fsnot.hidden.dir")
            if event.dirChange {
                if let project = project {
                    delegate.sidebarOutlineView.removeProject(project: project)
                }
            }
            
            return
        }

        let srcProject = self.storage.getProjects().first(where: { $0.moveSrc == dirURL })
        let dstProject = self.storage.getProjects().first(where: { $0.moveDst == dirURL })

        if event.dirRenamed {
            if let project = project {
                if dstProject != nil {
                    dstProject?.moveDst = nil
                } else {

                    // hack: occasionally get rename event when created
                    if !FileManager.default.fileExists(atPath: dirURL.path) {
                        self.delegate.sidebarOutlineView.removeProject(project: project)
                    }
                }
            } else {
                if srcProject != nil {
                    srcProject?.moveSrc = nil
                } else {
                    if FileManager.default.directoryExists(atUrl: dirURL) {
                        self.delegate.sidebarOutlineView.insertProject(url: dirURL)
                    }
                }
            }
            return
        }

        if event.dirRemoved  {
            if let project = project {
                self.delegate.sidebarOutlineView.removeProject(project: project)
            }
            return
        }

        // dirChange on xattr "es.fsnot.hidden.dir" changed
        if event.dirCreated || (
            event.dirChange && dirURL.hasNonHiddenBit()
        ) {
            self.delegate.sidebarOutlineView.insertProject(url: dirURL)
            return
        }
    }
    
    private func moveHandler(url: URL, pathList: [String]) {
        let fileExistInFS = self.checkFile(url: url, pathList: pathList)
        
        guard let note = self.storage.getBy(url: url) else {
            if fileExistInFS {
                self.importNote(url)
            }
            return
        }
        
        if fileExistInFS {
            renameNote(note: note)
            return
        }
        
        removeNote(note: note)
    }
    
    private func checkFile(url: URL, pathList: [String]) -> Bool {
        return (
            FileManager.default.fileExists(atPath: url.path)
            && (
                self.storage.allowedExtensions.contains(url.pathExtension)
                || self.storage.isValidUTI(url: url)
            )
            && pathList.contains(url.deletingLastPathComponent().path)
        )
    }
    
    private func importNote(_ url: URL) {
        let url = self.handleTextBundle(url: url)

        let n = storage.getBy(url: url)
        guard n == nil else {
            if let nUnwrapped = n, nUnwrapped.url == UserDataService.instance.focusOnImport {
                self.delegate.updateTable() {
                    self.delegate.notesTableView.setSelected(note: nUnwrapped)
                    UserDataService.instance.focusOnImport = nil
                }
                
            // When git checkout .textbundle/text.md system trigger remove/create events
            // but the note is not deleted, so the note must be reloaded
            } else if let nUnwrapped = n {
                reloadNote(note: nUnwrapped)
            }
            return
        }
        
        guard storage.getProjectByNote(url: url) != nil else {
            return
        }
        
        guard let note = storage.initNote(url: url) else { return }

        note.load()
        note.loadPreviewInfo()
        note.loadModifiedLocalAt()
        
        print("FSWatcher import note: \"\(note.name)\"")
        self.storage.add(note)
        self.storage.loadPins(notes: [note])
        
        DispatchQueue.main.async {
            if let url = UserDataService.instance.focusOnImport,
               let note = self.storage.getBy(url: url)
            {
                self.delegate.updateTable() {
                    self.delegate.notesTableView.setSelected(note: note)
                    UserDataService.instance.focusOnImport = nil
                }
            } else {
                if !note.isTrash() {
                    self.delegate.notesTableView.insertNew(note: note)
                }
            }
        }
    }
    
    private func renameNote(note: Note) {
        if note.url == UserDataService.instance.focusOnImport {
            self.delegate.updateTable() {
                self.delegate.notesTableView.setSelected(note: note)
                UserDataService.instance.focusOnImport = nil
            }
            
        // On TextBundle import
        } else {
            self.reloadNote(note: note)
        }
    }
    
    private func removeNote(note: Note) {
        print("FSWatcher remove note: \"\(note.name)\"")
        
        self.storage.removeNotes(notes: [note], fsRemove: false) { _ in
            DispatchQueue.main.async {
                if self.delegate.notesTableView.numberOfRows > 0 {
                    self.delegate.notesTableView.removeByNotes(notes: [note])
                }
            }
        }
    }
    
    private func reloadNote(note: Note) {
        guard note.container != .encryptedTextPack else { return }

        let memoryContent = note.content.attributedSubstring(from: NSRange(0..<note.content.length))
        guard var fsContent = note.getContent() else { return }

        // Trying load content from encrypted note with current password
        if note.url.pathExtension == "etp", let password = note.password, note.unLock(password: password) {
            fsContent = note.content
        }

        if (
            note.isRTF() && fsContent != memoryContent)
            || (
                !note.isRTF() && fsContent.string != memoryContent.string
            )
        {
            note.cacheHash = nil
            note.content = NSMutableAttributedString(attributedString: fsContent)

            // tags changes

            let result = note.scanContentTags()
            if result.0.count > 0 {
                DispatchQueue.main.async {
                    self.delegate.sidebarOutlineView.insertTags(note: note)
                }
            }

            if result.1.count > 0 {
                DispatchQueue.main.async {
                    self.delegate.sidebarOutlineView.removeTags(result.1)
                }
            }

            // reload view

            self.delegate.notesTableView.reloadRow(note: note)

            let editors = AppDelegate.getEditTextViews()
            for editor in editors {
                if editor.note == note {
                    DispatchQueue.main.async {
                        editor.editorViewController?.refillEditArea(force: true)
                    }
                }
            }
        } else if let modificationDate = note.getFileModifiedDate(), let creationDate = note.getFileCreationDate() {
            if modificationDate != note.modifiedLocalAt || creationDate != note.creationDate {
                note.modifiedLocalAt = modificationDate
                note.creationDate = creationDate
                delegate.notesTableView.reloadDate(note: note)
                
                // Reload images if note moved (cache invalidated)
                note.loadPreviewInfo()
            }
        }
    }
    
    private func handleTextBundle(url: URL) -> URL {
        if ["text.markdown", "text.md", "text.txt", "text.rtf"].contains(url.lastPathComponent) && url.path.contains(".textbundle") {
            let path = url.deletingLastPathComponent().path
            return URL(fileURLWithPath: path, isDirectory: false)
        }
        
        return url
    }
    
    public func restart() {
        watcher?.stop()
        self.observedFolders = self.storage.getProjectPaths()
        start()
    }

    public func reloadObservedFolders() {
        self.observedFolders = self.storage.getProjectPaths()
    }

    public func resolveConflict(url: URL) {
        if let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url as URL) {
            for conflict in conflicts {
                guard let modificationDate = conflict.modificationDate else {
                    continue
                }

                guard let localizedName = conflict.localizedName else {
                    continue
                }

                let localizedUrl = URL(fileURLWithPath: localizedName)
                let ext = url.pathExtension
                let name = localizedUrl.deletingPathExtension().lastPathComponent

                let dateFormatter = ISO8601DateFormatter()
                dateFormatter.formatOptions = [
                    .withYear,
                    .withMonth,
                    .withDay,
                    .withTime
                ]
                let dateString: String = dateFormatter.string(from: modificationDate)
                let conflictName = "\(name) (CONFLICT \(dateString)).\(ext)"

                let to = url.deletingLastPathComponent().appendingPathComponent(conflictName)

                if FileManager.default.fileExists(atPath: to.path) {
                    conflict.isResolved = true
                    continue
                }

                // Reload current encrypted note
                let editors = AppDelegate.getEditTextViews()
                for editor in editors {
                    if let currentNote = editor.note, currentNote.url == url {
                        if let password = currentNote.password, ext == "etp" {
                            _ = currentNote.unLock(password: password)
                        }

                        DispatchQueue.main.async {
                            editor.editorViewController?.refillEditArea(force: true)
                        }
                    }
                }
                
                do {
                    try FileManager.default.copyItem(at: conflict.url, to: to)
                    var attributes = [FileAttributeKey : Any]()
                    attributes[.posixPermissions] = 0o777
                    try FileManager.default.setAttributes(attributes, ofItemAtPath: to.path)
                }catch let error {
                    print("Conflict resolving error: ", error)
                }

                conflict.isResolved = true
            }
        }
    }
}
