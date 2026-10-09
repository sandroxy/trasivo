#if os(iOS)
import UIKit
import Trasivo

/// Retain this controller while the overlay is attached. All UI methods require the main thread.
public final class TransferOverlay {
    private weak var presenter: UIViewController?
    private weak var panel: TransferPanel?
    private let center: TransferCenter
    private let container = FloatingContainer()
    private var configuration: TransferUIConfiguration
    private var subscription: TransferSubscription?
    private var closed = false
    public init(center: TransferCenter, parent: UIView, presenter: UIViewController,
                configuration: TransferUIConfiguration = TransferUIConfiguration()) {
        precondition(Thread.isMainThread)
        self.center = center; self.presenter = presenter; self.configuration = configuration
        container.frame = parent.bounds; container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.bubble.action = { [weak self] in self?.showPanel() }
        parent.addSubview(container)
        subscription = center.observe { [weak self] tasks in
            DispatchQueue.main.async { [weak self] in
                guard let self = self, !self.closed else { return }
                self.container.configure(tasks, self.configuration)
            }
        }
        container.configure(center.snapshot(), configuration)
    }
    public func updateConfiguration(_ configuration: TransferUIConfiguration) {
        precondition(Thread.isMainThread); guard !closed else { return }
        self.configuration = configuration; container.configure(center.snapshot(), configuration)
        panel?.configure(configuration)
    }
    public func showPanel() {
        precondition(Thread.isMainThread)
        guard !closed, panel == nil, let presenter = presenter, presenter.presentedViewController == nil else { return }
        let panel = TransferPanel(center: center, configuration: configuration)
        self.panel = panel
        let navigation = UINavigationController(rootViewController: panel)
        navigation.modalPresentationStyle = .pageSheet
        if #available(iOS 15, *) { navigation.sheetPresentationController?.detents = [.medium(), .large()] }
        presenter.present(navigation, animated: true)
    }
    public func close() {
        precondition(Thread.isMainThread); guard !closed else { return }
        closed = true; subscription?.cancel(); subscription = nil; container.removeFromSuperview()
        panel?.navigationController?.dismiss(animated: true)
    }
    deinit {
        subscription?.cancel()
        let container = container
        if Thread.isMainThread { container.removeFromSuperview() }
        else { DispatchQueue.main.async { container.removeFromSuperview() } }
    }
}

final class ActionButton: UIButton {
    var action: (() -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame); addTarget(self, action: #selector(pressed), for: .touchUpInside)
        titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        titleLabel?.adjustsFontForContentSizeCategory = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    @objc private func pressed() { action?() }
}

private final class FloatingContainer: UIView {
    let bubble = ActionButton(frame: CGRect(x: 0, y: 0, width: 58, height: 58))
    private let track = CAShapeLayer(), ring = CAShapeLayer()
    private var positioned = false
    private var start = CGPoint.zero
    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(bubble); bubble.layer.cornerRadius = 29
        bubble.layer.shadowOpacity = 0.15; bubble.layer.shadowRadius = 6; bubble.layer.shadowOffset = CGSize(width: 0, height: 3)
        for layer in [track, ring] {
            layer.fillColor = UIColor.clear.cgColor; layer.lineWidth = 3
            layer.path = UIBezierPath(arcCenter: CGPoint(x: 29, y: 29), radius: 25, startAngle: -.pi / 2,
                                      endAngle: .pi * 1.5, clockwise: true).cgPath
            bubble.layer.addSublayer(layer)
        }
        bubble.titleLabel?.font = .systemFont(ofSize: 19, weight: .semibold)
        bubble.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(drag(_:))))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { !bubble.isHidden && bubble.frame.contains(point) }
    override func layoutSubviews() {
        super.layoutSubviews()
        if !positioned && bounds.width > 0 { bubble.center = CGPoint(x: bounds.width - 45, y: bounds.height * 0.68); positioned = true }
        clamp()
    }
    private func clamp() {
        let safe = bounds.inset(by: safeAreaInsets).insetBy(dx: 37, dy: 37)
        bubble.center.x = max(safe.minX, min(max(safe.minX, safe.maxX), bubble.center.x))
        bubble.center.y = max(safe.minY, min(max(safe.minY, safe.maxY), bubble.center.y))
    }
    @objc private func drag(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began { start = bubble.center }
        let delta = gesture.translation(in: self)
        bubble.center = CGPoint(x: start.x + delta.x, y: start.y + delta.y); clamp()
        if gesture.state == .ended || gesture.state == .cancelled {
            bubble.center.x = bubble.center.x < bounds.midX ? 0 : bounds.width; clamp()
        }
    }
    func configure(_ tasks: [TransferSnapshot], _ configuration: TransferUIConfiguration) {
        let active = tasks.filter(\.isActive), failed = tasks.filter { $0.state == .failed }
        let canceled = tasks.contains { $0.state == .canceled }
        let color = active.isEmpty ? (failed.isEmpty ? (canceled ? configuration.theme.mutedText : configuration.theme.success) : configuration.theme.danger) : configuration.theme.primary
        bubble.isHidden = tasks.isEmpty; bubble.backgroundColor = configuration.theme.surface
        bubble.setTitleColor(color, for: .normal)
        bubble.setTitle(active.isEmpty ? (failed.isEmpty ? (canceled ? "–" : "✓") : "!") : active.count > 99 ? "99+" : String(active.count), for: .normal)
        bubble.accessibilityLabel = configuration.text("bubble").replacingOccurrences(of: "{count}", with: String(active.count))
        track.strokeColor = configuration.theme.border.cgColor; ring.strokeColor = color.cgColor
        let total = active.reduce(0.0) { $0 + Double(max(0, $1.totalBytes)) }
        let bytes = active.reduce(0.0) { $0 + Double($1.completedBytes) }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        ring.strokeEnd = active.isEmpty ? 1 : active.contains { $0.totalBytes <= 0 } || total <= 0 ? 0.25 : CGFloat(min(0.99, bytes / total))
        CATransaction.commit()
    }
}

private final class TransferPanel: UIViewController, UITableViewDataSource, UITableViewDelegate {
    let center: TransferCenter
    var configuration: TransferUIConfiguration
    private var subscription: TransferSubscription?
    private var tasks: [TransferSnapshot] = [], visible: [TransferSnapshot] = []
    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private let segments = UISegmentedControl(items: ["", "", "", ""])
    private let empty = UILabel()
    init(center: TransferCenter, configuration: TransferUIConfiguration) {
        self.center = center; self.configuration = configuration; super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func viewDidLoad() {
        super.viewDidLoad()
        segments.selectedSegmentIndex = 0; segments.addTarget(self, action: #selector(reload), for: .valueChanged)
        table.dataSource = self; table.delegate = self; table.register(TransferCell.self, forCellReuseIdentifier: "task")
        table.rowHeight = UITableView.automaticDimension; table.estimatedRowHeight = 165
        for child in [segments, table] { child.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(child) }
        NSLayoutConstraint.activate([
            segments.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            segments.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            segments.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            segments.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
            table.topAnchor.constraint(equalTo: segments.bottomAnchor, constant: 8),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor), table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        empty.textAlignment = .center; empty.numberOfLines = 0; table.backgroundView = empty
        configure(configuration)
        subscription = center.observe { [weak self] value in DispatchQueue.main.async { [weak self] in self?.tasks = value; self?.reload() } }
    }
    func configure(_ configuration: TransferUIConfiguration) {
        self.configuration = configuration; guard isViewLoaded else { return }
        title = configuration.displayTitle; view.backgroundColor = configuration.theme.background
        table.backgroundColor = configuration.theme.background; table.separatorColor = configuration.theme.border
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: configuration.text("close"), style: .done, target: self, action: #selector(close))
        navigationController?.navigationBar.tintColor = configuration.theme.primary
        let appearance = UINavigationBarAppearance(); appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = configuration.theme.background; appearance.titleTextAttributes = [.foregroundColor: configuration.theme.text]
        navigationController?.navigationBar.standardAppearance = appearance; navigationController?.navigationBar.scrollEdgeAppearance = appearance
        for (index, key) in ["all", "active", "attention", "completed"].enumerated() { segments.setTitle(configuration.text(key), forSegmentAt: index) }
        segments.selectedSegmentTintColor = configuration.theme.surface
        segments.setTitleTextAttributes([.foregroundColor: configuration.theme.mutedText], for: .normal)
        segments.setTitleTextAttributes([.foregroundColor: configuration.theme.primary], for: .selected)
        empty.text = configuration.text("empty"); empty.textColor = configuration.theme.mutedText
        reload()
    }
    @objc private func close() { navigationController?.dismiss(animated: true) }
    @objc private func reload() {
        visible = tasks.filter { task in
            switch segments.selectedSegmentIndex { case 1: return task.isActive; case 2: return task.canRetry; case 3: return task.state == .succeeded; default: return true }
        }.reversed()
        empty.isHidden = !visible.isEmpty; table.reloadData()
    }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { visible.count }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "task", for: indexPath) as! TransferCell
        cell.configure(visible[indexPath.row], configuration, center); return cell
    }
}

private final class TransferCell: UITableViewCell {
    private let title = UILabel(), status = UILabel(), detail = UILabel(), bytes = UILabel()
    private let progress = UIProgressView(progressViewStyle: .default)
    private let waiting = UIActivityIndicatorView(style: .medium)
    private let actions = UIStackView()
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier); selectionStyle = .none
        title.font = .preferredFont(forTextStyle: .headline); title.numberOfLines = 2
        for label in [status, detail, bytes] { label.font = .preferredFont(forTextStyle: .caption1); label.numberOfLines = 0 }
        for label in [title, status, detail, bytes] { label.adjustsFontForContentSizeCategory = true }
        actions.axis = .horizontal; actions.spacing = 16; actions.distribution = .fillEqually
        let stack = UIStackView(arrangedSubviews: [title, status, progress, waiting, detail, bytes, actions]); stack.axis = .vertical; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16), stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    func configure(_ task: TransferSnapshot, _ configuration: TransferUIConfiguration, _ center: TransferCenter) {
        backgroundColor = configuration.theme.surface; title.text = task.title; title.textColor = configuration.theme.text
        let state = task.state == .finalizing ? "finalizing_" + task.direction.rawValue : task.state.rawValue
        status.text = configuration.text("task_status").replacingOccurrences(of: "{direction}", with: configuration.text(task.direction.rawValue)).replacingOccurrences(of: "{state}", with: configuration.text(state)); status.textColor = configuration.theme.mutedText
        detail.text = task.state == .failed ? configuration.error(task.errorCode) : nil; detail.textColor = configuration.theme.danger
        detail.isHidden = task.state != .failed
        bytes.text = configuration.text("byte_progress").replacingOccurrences(of: "{completed}", with: configuration.bytes(task.completedBytes)).replacingOccurrences(of: "{total}", with: configuration.bytes(task.totalBytes)); bytes.textColor = configuration.theme.mutedText
        let indeterminate = task.isActive && (task.totalBytes <= 0 || task.state == .finalizing)
        waiting.color = configuration.theme.primary; waiting.isHidden = !indeterminate
        if indeterminate { waiting.startAnimating() } else { waiting.stopAnimating() }
        progress.isHidden = !task.isActive || indeterminate; progress.progressTintColor = configuration.theme.primary; progress.trackTintColor = configuration.theme.border
        progress.progress = task.totalBytes <= 0 ? 0 : Float(min(0.99, Double(task.completedBytes) / Double(task.totalBytes)))
        for child in actions.arrangedSubviews { actions.removeArrangedSubview(child); child.removeFromSuperview() }
        func button(_ key: String, _ color: UIColor, _ action: @escaping () -> Void) {
            let button = ActionButton(frame: .zero); button.setTitle(configuration.text(key), for: .normal); button.setTitleColor(color, for: .normal)
            button.titleLabel?.numberOfLines = 2; button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            button.action = action; actions.addArrangedSubview(button)
        }
        if task.canRetry { button("retry", configuration.theme.primary) { center.retry(task.id) } }
        if task.canCancel { button("cancel", configuration.theme.danger) { center.cancel(task.id) } }
        if !task.isActive { button("remove", configuration.theme.mutedText) { center.remove(task.id) } }
        actions.isHidden = actions.arrangedSubviews.isEmpty
    }
}
#endif
