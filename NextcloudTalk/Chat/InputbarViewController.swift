//
// SPDX-FileCopyrightText: 2023 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import NextcloudKit
import PhotosUI
import UIKit

@objcMembers public class InputbarViewController: SLKTextViewController, NCChatTitleViewDelegate {

    // MARK: - Public var
    public var room: NCRoom
    public var account: TalkAccount

    // MARK: - Internal var
    internal var thread: NCThread?
    internal var titleView: NCChatTitleView?
    internal var autocompletionUsers: [MentionSuggestion] = []
    internal var mentionsDict: [String: NCMessageParameter] = [:]
    internal var contentView: UIView?
    internal var selectedAutocompletionRow: IndexPath?

    public var isThreadViewController: Bool {
        return thread != nil
    }

    public init?(forRoom room: NCRoom, withAccount account: TalkAccount, tableViewStyle style: UITableView.Style) {
        self.room = room
        self.account = account

        super.init(tableViewStyle: style)

        self.commonInit()
    }

    public init?(forRoom room: NCRoom, withAccount account: TalkAccount, withView view: UIView) {
        self.room = room
        self.account = account
        self.contentView = view

        super.init(tableViewStyle: .plain)

        self.commonInit()

        view.translatesAutoresizingMaskIntoConstraints = false

        self.view.addSubview(view)

        NSLayoutConstraint.activate([
            view.leftAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.leftAnchor),
            view.rightAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.rightAnchor),
            view.topAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.topAnchor),
            view.bottomAnchor.constraint(equalTo: self.textInputbar.topAnchor)
        ])

        // Make sure our contentView does not hide the inputBar and the autocompletionView
        self.view.bringSubviewToFront(self.textInputbar)
        self.view.bringSubviewToFront(self.autoCompletionView)
    }

    private func commonInit() {
        self.registerClass(forTextView: NCMessageTextView.self)
        self.registerClass(forReplyView: ReplyMessageView.self)
        self.registerClass(forTypingIndicatorView: TypingIndicatorView.self)
    }

    required init?(coder decoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        print("Dealloc InputbarViewController")
    }

    // MARK: - View lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()

        self.setTitleView()

        self.bounces = false
        self.shakeToClearEnabled = false

        // Set the rightButton early, to allow sizing the textInputbar correctly
        self.rightButton.setTitle("", for: .normal)
        self.rightButton.setImage(UIImage(systemName: "paperplane"), for: .normal)
        self.rightButton.accessibilityLabel = NSLocalizedString("Send message", comment: "")
        self.rightButton.accessibilityHint = NSLocalizedString("Double tap to send message", comment: "")

        self.textInputbar.autoHideRightButton = false
        self.textInputbar.counterStyle = .limitExceeded
        self.textInputbar.counterPosition = .top
        self.textInputbar.textView.isDynamicTypeEnabled = false
        self.textInputbar.textView.font = .preferredFont(forTextStyle: .body)

        let talkCapabilities = NCDatabaseManager.sharedInstance().roomTalkCapabilities(for: room)

        if let talkCapabilities, talkCapabilities.chatMaxLength > 0 {
            self.textInputbar.maxCharCount = UInt(talkCapabilities.chatMaxLength)
        } else {
            self.textInputbar.maxCharCount = 1000
            self.textInputbar.counterStyle = .countdownReversed
        }

        self.textInputbar.semanticContentAttribute = .forceLeftToRight
        self.textInputbar.contentInset = .init(top: 8, left: 8, bottom: 8, right: 8)
        self.textView.textContainerInset = .init(top: 8, left: 12, bottom: 8, right: 12)

        self.textView.layoutSubviews()

        // Need a compile-time check here for old xcode version on CI
#if swift(>=5.9)
        if #available(iOS 17.0, *), NCUtils.isiOSAppOnMac() {
            self.textView.inlinePredictionType = .no
        }
#endif

        self.textView.allowsEditingTextAttributes = false
        if #available(iOS 18.0, *) {
            self.textView.supportsAdaptiveImageGlyph = false
        }

        self.textInputbar.editorTitle.textColor = .darkGray
        self.textInputbar.editorLeftButton.tintColor = .systemBlue
        self.textInputbar.editorRightButton.tintColor = .systemBlue

        self.textInputbar.editorLeftButton.setImage(.init(systemName: "xmark"), for: .normal)
        self.textInputbar.editorRightButton.setImage(.init(systemName: "checkmark"), for: .normal)

        self.textInputbar.editorLeftButton.setTitle("", for: .normal)
        self.textInputbar.editorRightButton.setTitle("", for: .normal)

        NCAppBranding.styleViewController(self)

        // Ensure that we only show an arrow and not the full "Back" text
        self.navigationItem.backButtonDisplayMode = .minimal

        self.view.backgroundColor = .systemBackground
        self.tableView?.backgroundColor = .systemBackground
        self.styleFloatingComposerChrome()

        self.textInputbar.editorTitle.textColor = .label
        self.styleMessageInputChrome()

        self.textView.delegate = self

        self.view.bringSubviewToFront(self.autoCompletionView)
        self.view.bringSubviewToFront(self.textInputbar)

        self.autoCompletionView.register(AutoCompletionTableViewCell.self, forCellReuseIdentifier: AutoCompletionTableViewCell.identifier)
        self.registerPrefixes(forAutoCompletion: ["@"])

        self.autoCompletionView.backgroundColor = .systemBackground
        self.autoCompletionView.sectionHeaderTopPadding = 0

        // Align separators to ChatMessageTableViewCell's title label
        self.autoCompletionView.separatorInset = .init(top: 0, left: 50, bottom: 0, right: 0)

        // We can't use UIColor with systemBlueColor directly, because it will switch to indigo. So make sure we actually get a blue tint here
        self.textView.tintColor = UIColor(cgColor: UIColor.systemBlue.cgColor)

        // Markdown formatting options
        if NCDatabaseManager.sharedInstance().serverHasTalkCapability(.markdownMessages) {
            self.textView.registerMarkdownFormattingSymbol("**", withTitle: NSLocalizedString("Bold", comment: "Bold text"))
            self.textView.registerMarkdownFormattingSymbol("_", withTitle: NSLocalizedString("Italic", comment: "Italic text"))
            self.textView.registerMarkdownFormattingSymbol("~~", withTitle: NSLocalizedString("Strikethrough", comment: "Strikethrough text"))
            self.textView.registerMarkdownFormattingSymbol("`", withTitle: NSLocalizedString("Code", comment: "Code block"))
        }

        self.tableView?.clipsToBounds = true

        self.restorePendingMessage()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        self.updateMessageInputChromeCorners()
    }

    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        if self.traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            self.textView.tintColor = UIColor(cgColor: UIColor.systemBlue.cgColor)
            // Border uses CGColor — refresh fill + stroke for the new appearance.
            self.styleMessageInputChrome()

            self.setTitleView()
        } else if previousTraitCollection?.horizontalSizeClass != self.traitCollection.horizontalSizeClass || previousTraitCollection?.verticalSizeClass != self.traitCollection.verticalSizeClass {
            // When the size class changes, we want to update the title view (e.g. to show/hide subtitle)
            self.setTitleView()
        }
    }

    // MARK: - Message input chrome (Telegram-style)

    /// Stronger than `secondarySystemFill` so the field/buttons stay visible on white and black chat backgrounds.
    static var messageComposerChromeFill: UIColor {
        UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                // Lift off pure black (systemGray4 ≈ #3A3A3C)
                return .systemGray4
            }
            // Distinct from white / systemBackground (systemGray5 ≈ #E5E5EA)
            return .systemGray5
        }
    }

    static var messageComposerChromeStroke: UIColor {
        UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                return UIColor.white.withAlphaComponent(0.18)
            }
            return UIColor.black.withAlphaComponent(0.12)
        }
    }

    /// Transparent bar so the chat list shows through behind + / field / send.
    func styleFloatingComposerChrome() {
        // SLKTextInputbar is a UIView (not UIToolbar) — only clear its background.
        self.textInputbar.backgroundColor = .clear
        self.textInputbar.isOpaque = false
    }

    /// Filled pill field + circular action buttons with enough contrast for light and dark mode.
    func styleMessageInputChrome() {
        self.styleFloatingComposerChrome()

        let fill = Self.messageComposerChromeFill
        let stroke = Self.messageComposerChromeStroke.cgColor

        self.textView.backgroundColor = fill
        self.textView.layer.borderWidth = 1.0 / UIScreen.main.scale
        self.textView.layer.borderColor = stroke
        self.textView.clipsToBounds = true
        if let messageTextView = self.textView as? NCMessageTextView {
            messageTextView.placeholderColor = .secondaryLabel
        }

        self.styleMessageInputActionButton(self.leftButton, fill: fill, stroke: stroke)
        self.styleMessageInputActionButton(self.rightButton, fill: fill, stroke: stroke)
        self.updateMessageInputChromeCorners()
    }

    private func styleMessageInputActionButton(_ button: UIButton, fill: UIColor, stroke: CGColor) {
        button.backgroundColor = fill
        button.tintColor = .label
        button.clipsToBounds = true
        button.layer.borderWidth = 1.0 / UIScreen.main.scale
        button.layer.borderColor = stroke
    }

    private func updateMessageInputChromeCorners() {
        let textHeight = self.textView.bounds.height
        if textHeight > 0 {
            self.textView.layer.cornerRadius = textHeight / 2
        }

        for button in [self.leftButton, self.rightButton] {
            let side = min(button.bounds.width, button.bounds.height)
            if side > 0 {
                button.layer.cornerRadius = side / 2
            }
        }
    }

    // MARK: - Configuration

    func setTitleView() {
        /*
        // This is uses the native iOS 26 navigationItem properties, but currently misses tap action
        if #available(iOS 26.0, *) {
            self.navigationItem.style = .editor

            let avatarView = AvatarButton(frame: .init(x: 0, y: 0, width: 44, height: 44))

            if let thread = self.thread, let firstMessage = thread.firstMessage() {
                avatarView.setActorAvatar(forMessage: firstMessage, withAccount: self.account)
                self.navigationItem.title = thread.title
            } else {
                avatarView.setAvatar(for: room)
                self.navigationItem.title = room.displayName
                self.navigationItem.subtitle = room.roomDescription
            }

            avatarView.widthAnchor.constraint(equalToConstant: 44).isActive = true
            avatarView.heightAnchor.constraint(equalToConstant: 44).isActive = true

            let avatarBarButton = UIBarButtonItem(customView: avatarView)
            avatarBarButton.tintColor = .clear
            avatarBarButton.hidesSharedBackground = true

            self.navigationItem.leftItemsSupplementBackButton = true
            self.navigationItem.leftBarButtonItems = [avatarBarButton]

            return
        }
        */

        let titleView = NCChatTitleView()

        // Int.max is problematic when running on MacOS, so we use Int32.max here
        titleView.frame = .init(x: 0, y: 0, width: Int(Int32.max), height: 30)
        titleView.delegate = self
        titleView.titleTextView.accessibilityHint = NSLocalizedString("Double tap to go to conversation information", comment: "")

        if #available(iOS 26.0, *) {
            // Need to constraint the height here, otherwise we render way too large
            titleView.heightAnchor.constraint(equalToConstant: 44).isActive = true
            titleView.widthAnchor.constraint(equalToConstant: CGFloat.greatestFiniteMagnitude).isActive = true
        }

        if self.navigationController?.traitCollection.verticalSizeClass == .compact {
            titleView.showSubtitle = false
        }

        if let thread {
            titleView.update(for: thread)
            titleView.longPressGestureRecognizer.isEnabled = false
        } else {
            titleView.update(for: self.room)
        }

        self.titleView = titleView
        self.navigationItem.titleView = titleView
    }

    // MARK: - Autocompletion

    public override func didChangeAutoCompletionPrefix(_ prefix: String, andWord word: String) {
        if prefix == "@" {
            self.showSuggestions(for: word)
        }
    }

    public override func heightForAutoCompletionView() -> CGFloat {
        return AutoCompletionTableViewCell.cellHeight * CGFloat(self.autocompletionUsers.count) + (self.autoCompletionView.tableHeaderView?.frame.height ?? 0)
    }

    func showSuggestions(for string: String) {
        self.autocompletionUsers = []

        NCAPIController.sharedInstance().getMentionSuggestions(for: self.room.accountId, in: self.room.token, with: string) { mentions in
            guard let mentions else { return }

            self.autocompletionUsers = mentions
            let showAutocomplete = !self.autocompletionUsers.isEmpty

            // Check if "@" is still there
            self.textView.look(forPrefixes: self.registeredPrefixes) { prefix, word, _ in
                self.selectedAutocompletionRow = nil

                if prefix?.count ?? 0 > 0 && word?.count ?? 0 > 0 {
                    self.showAutoCompletionView(showAutocomplete)
                } else {
                    self.cancelAutoCompletion()
                }
            }
        }
    }

    internal func replaceMentionsDisplayNamesWithMentionsKeysInMessage(message: String, parameters: String) -> String {
        var resultMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let messageParametersDict = [String: NCMessageParameter].fromJSONString(parameters) else { return resultMessage }

        for (parameterKey, parameter) in messageParametersDict {
            guard let mention = parameter.mention else { continue }

            let parameterKeyString = "{\(parameterKey)}"
            resultMessage = resultMessage.replacingOccurrences(of: mention.labelForChat, with: parameterKeyString)
        }

        return resultMessage
    }

    override public func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard self.isAutoCompleting, !self.autocompletionUsers.isEmpty
        else {
            super.pressesBegan(presses, with: event)
            return
        }

        let oldIndexPath = self.selectedAutocompletionRow ?? IndexPath(row: 0, section: 0)
        var newIndexPath: IndexPath?

        // Support selecting the auto complete with return/enter key
        if presses.contains(where: { $0.key?.keyCode == .keyboardReturnOrEnter }) {
            self.acceptAutoCompletion(withIndexPath: oldIndexPath)

            return
        } else if presses.contains(where: { $0.key?.keyCode == .keyboardUpArrow }) {
            newIndexPath = IndexPath(row: oldIndexPath.row - 1, section: 0)
        } else if presses.contains(where: { $0.key?.keyCode == .keyboardDownArrow }) {
            newIndexPath = IndexPath(row: oldIndexPath.row + 1, section: 0)
        }

        if let newIndexPath, self.autoCompletionView.isValid(indexPath: newIndexPath) {
            self.selectedAutocompletionRow = newIndexPath
            self.autoCompletionView.reloadRows(at: [oldIndexPath, newIndexPath], with: .none)
            self.autoCompletionView.scrollToRow(at: newIndexPath, at: .none, animated: true)

            return
        }

        super.pressesBegan(presses, with: event)
    }

    // MARK: - UITableViewDataSource methods

    public override func numberOfSections(in tableView: UITableView) -> Int {
        if tableView == self.autoCompletionView {
            return 1
        }

        return 0
    }

    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if tableView == self.autoCompletionView {
            return self.autocompletionUsers.count
        }

        return 0
    }

    public override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return nil
    }

    public override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return 0
    }

    public override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        return nil
    }

    public override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard tableView == self.autoCompletionView,
              indexPath.row < self.autocompletionUsers.count,
              let cell = self.autoCompletionView.dequeueReusableCell(withIdentifier: AutoCompletionTableViewCell.identifier) as? AutoCompletionTableViewCell
        else {
            return AutoCompletionTableViewCell(style: .default, reuseIdentifier: AutoCompletionTableViewCell.identifier)
        }

        let suggestion = self.autocompletionUsers[indexPath.row]

        if let details = suggestion.details {
            cell.titleLabel.numberOfLines = 2

            let attributedLabel = (suggestion.mention.label + "\n").withFont(.preferredFont(forTextStyle: .body))
            let attributedDetails = details.withFont(.preferredFont(forTextStyle: .callout)).withTextColor(.secondaryLabel)
            attributedLabel.append(attributedDetails)
            cell.titleLabel.attributedText = attributedLabel
        } else {
            cell.titleLabel.numberOfLines = 1
            cell.titleLabel.text = suggestion.mention.label
        }

        if let suggestionUserStatus = suggestion.userStatus {
            cell.setUserStatus(suggestionUserStatus)
        }

        if suggestion.mention.id == "all" {
            cell.avatarButton.setAvatar(for: self.room)
        } else {
            cell.avatarButton.setActorAvatar(forId: suggestion.mention.id, withType: suggestion.source, withDisplayName: suggestion.mention.label, withRoomToken: self.room.token, using: self.account)
        }

        if let selectedAutocompletionRow, selectedAutocompletionRow == indexPath {
            cell.layer.borderColor = UIColor.systemGray.cgColor
            cell.layer.borderWidth = 2.0
        } else {
            cell.layer.borderWidth = 0.0
        }

        cell.accessibilityIdentifier = AutoCompletionTableViewCell.identifier
        return cell
    }

    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard tableView == self.autoCompletionView else { return }

        self.acceptAutoCompletion(withIndexPath: indexPath)
    }

    private func acceptAutoCompletion(withIndexPath indexPath: IndexPath) {
        guard indexPath.row < self.autocompletionUsers.count else { return }

        let suggestion = self.autocompletionUsers[indexPath.row]

        let mentionKey = "mention-\(self.mentionsDict.count)"
        self.mentionsDict[mentionKey] = suggestion.asMessageParameter()

        let mentionWithWhitespace = suggestion.mention.label + " "
        self.acceptAutoCompletion(with: mentionWithWhitespace, keepPrefix: true)
        self.selectedAutocompletionRow = nil
    }

    public override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return AutoCompletionTableViewCell.cellHeight
    }

    // MARK: - TextView functiosn

    public func setChatMessage(_ chatMessage: String) {
        DispatchQueue.main.async {
            self.textView.text = chatMessage
        }
    }

    public func restorePendingMessage() {
        if let pendingMessage = self.room.pendingMessage {
            self.setChatMessage(pendingMessage)
        }
    }

    public override func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        if text.isEmpty, let selectedRange = textView.selectedTextRange, let text = textView.text {
            let cursorOffset = textView.offset(from: textView.beginningOfDocument, to: selectedRange.start)
            let substring = (text as NSString).substring(to: cursorOffset)

            if var lastPossibleMention = substring.components(separatedBy: "@").last {
                for (mentionKey, mentionParameter) in self.mentionsDict {
                    guard let mention = mentionParameter.mention else { continue }

                    if lastPossibleMention != mention.label {
                        continue
                    }

                    lastPossibleMention.insert("@", at: lastPossibleMention.startIndex)

                    // Delete mention
                    let range = NSRange(location: cursorOffset - lastPossibleMention.utf16.count, length: lastPossibleMention.utf16.count)
                    textView.text = (text as NSString).replacingCharacters(in: range, with: "")

                    // Only delete it from mentionsDict if there are no more mentions for that user/room
                    // User could have manually added the mention without selecting it from autocompletion
                    // so no mention was added to the mentionsDict
                    if (textView.text as NSString).range(of: lastPossibleMention).location != NSNotFound {
                        self.mentionsDict.removeValue(forKey: mentionKey)
                    }

                    return true
                }
            }
        }

        return super.textView(textView, shouldChangeTextIn: range, replacementText: text)
    }

    // MARK: - TitleView delegate

    public func chatTitleViewTapped(_ titleView: NCChatTitleView) {
        // Doing nothing here -> override in subclass
    }

}
