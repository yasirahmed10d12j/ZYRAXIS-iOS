//
//  RemoteDesktopViewController.swift
//  ZYRAXIS-iOS
//
//  Remote desktop viewer + input controller.
//

import UIKit
import Combine

public final class RemoteDesktopViewController: UIViewController {

    private let service: RemoteDesktopService
    private let sessionKey: String

    private let imageView = UIImageView()
    private var cancellables = Set<AnyCancellable>()
    private let keyboardField = UITextField()
    /// Always sits in the hidden field so backspace always has something to
    /// delete — UIKit does NOT call the delegate when you press delete on an
    /// empty text field, and every change is rejected (the PC owns the text).
    private let keyboardSentinel = "\u{200B}"
    private let statusLabel = UILabel()
    private let touchMarker = UIView()
    private var scrollAccum: CGFloat = 0
    private var lastMoveSent: TimeInterval = 0

    public init(service: RemoteDesktopService, sessionKey: String) {
        self.service = service
        self.sessionKey = sessionKey
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .black
        view.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: view.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        // Connection status (the navigation bar is hidden in this sheet, so
        // the title alone would be invisible).
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.text = "Connecting…"
        statusLabel.textColor = .white
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        statusLabel.layer.cornerRadius = 8
        statusLabel.layer.masksToBounds = true
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            statusLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
        ])

        service.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .connected:
                    self.title = "ZYRAXIS Remote"
                    self.statusLabel.isHidden = true
                case .connecting:
                    self.title = "Connecting"
                    self.statusLabel.text = "Connecting…"
                    self.statusLabel.isHidden = false
                case .disconnected:
                    self.title = "Disconnected"
                    self.statusLabel.text = "Disconnected"
                    self.statusLabel.isHidden = false
                case .error(let msg):
                    self.title = "Error: \(msg)"
                    self.statusLabel.text = msg
                    self.statusLabel.isHidden = false
                }
            }
            .store(in: &cancellables)

        service.$currentFrame
            .receive(on: DispatchQueue.main)
            .sink { [weak self] image in
                self?.imageView.image = image
            }
            .store(in: &cancellables)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        view.addGestureRecognizer(tap)

        // The remote frames don't include the mouse cursor, so show a local
        // marker where the finger touched (that IS where the cursor moved to).
        touchMarker.bounds = CGRect(x: 0, y: 0, width: 34, height: 34)
        touchMarker.layer.cornerRadius = 17
        touchMarker.backgroundColor = UIColor.white.withAlphaComponent(0.25)
        touchMarker.layer.borderColor = UIColor.white.withAlphaComponent(0.9).cgColor
        touchMarker.layer.borderWidth = 1.5
        touchMarker.isUserInteractionEnabled = false
        touchMarker.isHidden = true
        view.addSubview(touchMarker)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delaysTouchesBegan = false
        view.addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        view.addGestureRecognizer(pinch)

        setUpKeyboard()

        // Nobody else calls connect() — opening this viewer starts the session.
        Task {
            do {
                try await service.connect(sessionKey: sessionKey)
            } catch {
                // connect() already published the error onto $state.
            }
        }
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Closing the sheet ends our session. The shared socket stays up
        // (chat/voice keep working) — see endSession().
        service.endSession()
    }

    // MARK: - Keyboard

    /// Invisible field: the system keyboard types straight into the remote
    /// desktop. The keyboard button raises it; Done dismisses it.
    private func setUpKeyboard() {
        keyboardField.delegate = self
        keyboardField.autocorrectionType = .no
        keyboardField.autocapitalizationType = .none
        keyboardField.spellCheckingType = .no
        keyboardField.smartQuotesType = .no
        keyboardField.smartDashesType = .no
        keyboardField.smartInsertDeleteType = .no
        keyboardField.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        keyboardField.alpha = 0.02
        keyboardField.text = keyboardSentinel
        view.addSubview(keyboardField)

        let bar = UIToolbar()
        bar.sizeToFit()
        bar.items = [
            UIBarButtonItem(title: "Typing on remote PC", style: .plain, target: nil, action: nil),
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
            UIBarButtonItem(title: "Done", style: .done, target: self, action: #selector(dismissKeyboard)),
        ]
        keyboardField.inputAccessoryView = bar

        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "keyboard"), for: .normal)
        button.tintColor = .white
        button.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        button.layer.cornerRadius = 22
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(showKeyboard), for: .touchUpInside)
        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 44),
            button.heightAnchor.constraint(equalToConstant: 44),
            button.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            button.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])
    }

    @objc private func showKeyboard() {
        keyboardField.becomeFirstResponder()
    }

    @objc private func dismissKeyboard() {
        keyboardField.resignFirstResponder()
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, imageView.image != nil else { return }
        let point = gesture.location(in: view)
        showMarker(at: point)
        Task {
            do {
                try await service.sendInput(RemoteInputEvent(
                    sessionKey: sessionKey,
                    kind: .mouse,
                    x: Int(normalize(point: point).x),
                    y: Int(normalize(point: point).y),
                    button: "left",
                    doubleClick: gesture.numberOfTapsRequired == 2
                ))
            } catch {
                print("Send input error: \(error)")
            }
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard imageView.image != nil else { return }
        let point = gesture.location(in: view)
        switch gesture.state {
        case .began:
            showMarker(at: point)
            sendMouseMove(to: point, down: true)
        case .changed:
            showMarker(at: point)
            // Drag moves fire at display refresh rate — throttle to ~12/s.
            sendMouseMove(to: point, down: true, throttle: true)
        case .ended, .cancelled:
            showMarker(at: point)
            sendMouseMove(to: point, down: false)
        default:
            break
        }
    }

    /// Brief ring at the touch point — the streamed frames have no cursor.
    private func showMarker(at point: CGPoint) {
        touchMarker.center = point
        touchMarker.isHidden = false
        touchMarker.layer.removeAllAnimations()
        touchMarker.alpha = 1
        UIView.animate(withDuration: 0.7, delay: 0.3, options: [.allowUserInteraction]) {
            self.touchMarker.alpha = 0
        } completion: { _ in
            self.touchMarker.isHidden = true
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard gesture.state == .changed || gesture.state == .ended else { return }
        // Spread fingers = scroll up, pinch in = scroll down. Accumulate so a
        // fast pinch doesn't flood the hub with dozens of tiny wheel events.
        scrollAccum += (gesture.scale - 1.0) * 8
        gesture.scale = 1.0
        let detents = Int(scrollAccum / 2)
        guard detents != 0 else { return }
        scrollAccum -= CGFloat(detents) * 2
        Task {
            do {
                try await service.sendInput(RemoteInputEvent(
                    sessionKey: sessionKey,
                    kind: .mouse,
                    scrollY: detents
                ))
            } catch {
                print("Send scroll error: \(error)")
            }
        }
    }

    private func sendMouseMove(to point: CGPoint, down: Bool, throttle: Bool = false) {
        if throttle {
            let now = Date().timeIntervalSince1970
            guard now - lastMoveSent >= 0.08 else { return }
            lastMoveSent = now
        }
        Task {
            do {
                try await service.sendInput(RemoteInputEvent(
                    sessionKey: sessionKey,
                    kind: .mouse,
                    x: Int(normalize(point: point).x),
                    y: Int(normalize(point: point).y),
                    button: "left",
                    doubleClick: false,
                    down: down
                ))
            } catch {
                print("Send move error: \(error)")
            }
        }
    }

    private func normalize(point: CGPoint) -> CGPoint {
        guard let image = imageView.image else { return .zero }
        let viewSize = view.bounds.size
        let imageSize = image.size

        let viewRatio = viewSize.width / viewSize.height
        let imageRatio = imageSize.width / imageSize.height

        var drawRect: CGRect
        if viewRatio > imageRatio {
            let h = viewSize.height
            let w = h * imageRatio
            drawRect = CGRect(x: (viewSize.width - w) / 2, y: 0, width: w, height: h)
        } else {
            let w = viewSize.width
            let h = w / imageRatio
            drawRect = CGRect(x: 0, y: (viewSize.height - h) / 2, width: w, height: h)
        }

        let relativeX = (point.x - drawRect.origin.x) / drawRect.width
        let relativeY = (point.y - drawRect.origin.y) / drawRect.height

        return CGPoint(x: relativeX * imageSize.width, y: relativeY * imageSize.height)
    }
}

// MARK: - Remote keyboard

extension RemoteDesktopViewController: UITextFieldDelegate {

    public func textField(_ textField: UITextField,
                          shouldChangeCharactersIn range: NSRange,
                          replacementString string: String) -> Bool {
        if string.isEmpty {
            // Backspace / delete (possible because of the sentinel).
            if range.length > 0 { sendKey("backspace") }
        } else {
            sendKey(string)
        }
        // The remote machine owns the text, never this hidden field.
        if textField.text != keyboardSentinel { textField.text = keyboardSentinel }
        return false
    }

    public func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        sendKey("enter")
        return false
    }

    private func sendKey(_ key: String) {
        Task {
            do {
                try await service.sendInput(RemoteInputEvent(
                    sessionKey: sessionKey,
                    kind: .key,
                    key: key
                ))
            } catch {
                print("Send key error: \(error)")
            }
        }
    }
}
