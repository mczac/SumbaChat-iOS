//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

protocol BotCellDelegate: AnyObject {
    func changeBotState(_ cell: BotCell, bot: Bot)
}

class BotCell: UITableViewCell {

    public static let identifier = "BotCell"

    public weak var delegate: BotCellDelegate?

    @IBOutlet weak var titleLabel: UILabel!
    @IBOutlet weak var detailsLabel: UILabel!
    @IBOutlet weak var enableSwitch: UISwitch!

    private var bot: Bot?

    override func awakeFromNib() {
        super.awakeFromNib()

        self.selectionStyle = .none
        self.enableSwitch.addTarget(self, action: #selector(changeBotStatePressed), for: .valueChanged)
    }

    override func prepareForReuse() {
        super.prepareForReuse()

        self.titleLabel.text = ""
        self.detailsLabel.text = ""
        self.bot = nil

        self.setEnabledState()
    }

    public func setupFor(bot: Bot) {
        self.bot = bot

        self.titleLabel.text = bot.name
        self.detailsLabel.text = NSLocalizedString("Sumba Talk assistant", comment: "Short description for the room bot")

        self.enableSwitch.isEnabled = true

        switch bot.state {
        case .disabled:
            self.enableSwitch.isOn = false
        case .enabled:
            self.enableSwitch.isOn = true
        case .noSetup:
            self.enableSwitch.isOn = true
            self.enableSwitch.isEnabled = false
        default:
            self.enableSwitch.isOn = false
            self.enableSwitch.isEnabled = false
        }
    }

    public func setDisabledState() {
        self.contentView.isUserInteractionEnabled = false
        self.contentView.alpha = 0.5
    }

    public func setEnabledState() {
        self.contentView.isUserInteractionEnabled = true
        self.contentView.alpha = 1
    }

    @objc
    func changeBotStatePressed() {
        guard let bot else { return }

        self.delegate?.changeBotState(self, bot: bot)
    }
}
