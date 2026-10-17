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

        service.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                switch state {
                case .connected:
                    self?.title = "ZYRAXIS Remote"
                case .disconnected:
                    self?.title = "Disconnected"
                case .error(let msg):
                    self?.title = "Error: \(msg)"
                default:
                    break
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

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delaysTouchesBegan = false
        view.addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        view.addGestureRecognizer(pinch)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let point = gesture.location(in: view)
        Task {
            do {
                try await service.sendInput(RemoteInputEvent(
                    sessionKey: sessionKey,
                    kind: .mouse,
                    x: Int(normalize(point: point).x),
                    y: Int(normalize(point: point).y),
                    button: "left",
                    doubleClick: gesture.numberOfTaps == 2
                ))
            } catch {
                print("Send input error: \(error)")
            }
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: view)
        switch gesture.state {
        case .began:
            sendMouseMove(to: point, press: true)
        case .changed:
            sendMouseMove(to: point, press: true)
        case .ended, .cancelled:
            sendMouseMove(to: point, press: false)
        default:
            break
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard gesture.state == .changed || gesture.state == .ended else { return }
        let scrollY = Int(gesture.velocity > 0 ? -3 : 3)
        Task {
            do {
                try await service.sendInput(RemoteInputEvent(
                    sessionKey: sessionKey,
                    kind: .mouse,
                    scrollY: scrollY
                ))
            } catch {
                print("Send scroll error: \(error)")
            }
        }
        gesture.scale = 1.0
    }

    private func sendMouseClick(at point: CGPoint, double: Bool) {
        Task {
            do {
                try await service.sendInput(RemoteInputEvent(
                    sessionKey: sessionKey,
                    kind: .mouse,
                    x: Int(normalize(point: point).x),
                    y: Int(normalize(point: point).y),
                    button: "left",
                    doubleClick: double
                ))
            } catch {
                print("Send click error: \(error)")
            }
        }
    }

    private func sendMouseMove(to point: CGPoint, press: Bool) {
        Task {
            do {
                try await service.sendInput(RemoteInputEvent(
                    sessionKey: sessionKey,
                    kind: .mouse,
                    x: Int(normalize(point: point).x),
                    y: Int(normalize(point: point).y),
                    button: press ? "left" : nil,
                    doubleClick: false
                ))
            } catch {
                print("Send move error: \(error)")
            }
        }
    }

    private func sendScroll(dy: Int) {
        Task {
            do {
                try await service.sendInput(RemoteInputEvent(
                    sessionKey: sessionKey,
                    kind: .mouse,
                    scrollY: dy
                ))
            } catch {
                print("Send scroll error: \(error)")
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
