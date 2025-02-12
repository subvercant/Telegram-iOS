import Foundation
import UIKit
import AsyncDisplayKit
import Display
import TelegramPresentationData

struct EditableTokenListToken {
    let id: AnyHashable
    let title: String
}

private let caretIndicatorImage = generateVerticallyStretchableFilledCircleImage(radius: 1.0, color: UIColor(rgb: 0x3350ee))

private func caretAnimation() -> CAAnimation {
    let animation = CAKeyframeAnimation(keyPath: "opacity")
    animation.values = [1.0 as NSNumber, 0.0 as NSNumber, 1.0 as NSNumber, 1.0 as NSNumber]
    let firstDuration = 0.3
    let secondDuration = 0.25
    let restDuration = 0.35
    let duration = firstDuration + secondDuration + restDuration
    let keyTimes: [NSNumber] = [0.0 as NSNumber, (firstDuration / duration) as NSNumber, ((firstDuration + secondDuration) / duration) as NSNumber, ((firstDuration + secondDuration + restDuration) / duration) as NSNumber]
    
    animation.keyTimes = keyTimes
    animation.duration = duration
    animation.repeatCount = Float.greatestFiniteMagnitude
    return animation
}

final class EditableTokenListNodeTheme {
    let backgroundColor: UIColor
    let separatorColor: UIColor
    let placeholderTextColor: UIColor
    let primaryTextColor: UIColor
    let selectedTextColor: UIColor
    let keyboardColor: PresentationThemeKeyboardColor
    
    init(backgroundColor: UIColor, separatorColor: UIColor, placeholderTextColor: UIColor, primaryTextColor: UIColor, selectedTextColor: UIColor, keyboardColor: PresentationThemeKeyboardColor) {
        self.backgroundColor = backgroundColor
        self.separatorColor = separatorColor
        self.placeholderTextColor = placeholderTextColor
        self.primaryTextColor = primaryTextColor
        self.selectedTextColor = selectedTextColor
        self.keyboardColor = keyboardColor
    }
}

private final class TokenNode: ASDisplayNode {
    let theme: EditableTokenListNodeTheme
    let token: EditableTokenListToken
    let titleNode: ASTextNode
    var isSelected: Bool {
        didSet {
            if self.isSelected != oldValue {
                self.titleNode.attributedText = NSAttributedString(string: token.title + ",", font: Font.regular(15.0), textColor: self.isSelected ? self.theme.selectedTextColor : self.theme.primaryTextColor)
            }
        }
    }
    
    init(theme: EditableTokenListNodeTheme, token: EditableTokenListToken, isSelected: Bool) {
        self.theme = theme
        self.token = token
        self.titleNode = ASTextNode()
        self.titleNode.isUserInteractionEnabled = false
        self.titleNode.maximumNumberOfLines = 1
        self.isSelected = isSelected
        
        super.init()
        
        self.titleNode.attributedText = NSAttributedString(string: token.title + ",", font: Font.regular(15.0), textColor: self.isSelected ? self.theme.selectedTextColor : self.theme.primaryTextColor)
        self.addSubnode(self.titleNode)
    }
    
    override func calculateSizeThatFits(_ constrainedSize: CGSize) -> CGSize {
        let titleSize = self.titleNode.measure(CGSize(width: constrainedSize.width - 8.0, height: constrainedSize.height))
        return CGSize(width: titleSize.width + 8.0, height: 28.0)
    }
    
    override func layout() {
        let titleSize = self.titleNode.calculatedSize
        if titleSize.width.isZero {
            return
        }
        self.titleNode.frame = CGRect(origin: CGPoint(x: 4.0, y: floor((self.bounds.size.height - titleSize.height) / 2.0)), size: titleSize)
    }
}

private final class CaretIndicatorNode: ASImageNode {
    override func willEnterHierarchy() {
        super.willEnterHierarchy()
        
        if self.layer.animation(forKey: "blink") == nil {
            self.layer.add(caretAnimation(), forKey: "blink")
        }
    }
}

final class EditableTokenListNode: ASDisplayNode, UITextFieldDelegate {
    private let theme: EditableTokenListNodeTheme
    private let scrollNode: ASScrollNode
    private let placeholderNode: ASTextNode
    private var tokenNodes: [TokenNode] = []
    private let separatorNode: ASDisplayNode
    private let textFieldNode: TextFieldNode
    private let caretIndicatorNode: CaretIndicatorNode
    private var selectedTokenId: AnyHashable?
    
    var textUpdated: ((String) -> Void)?
    var deleteToken: ((AnyHashable) -> Void)?
    
    init(theme: EditableTokenListNodeTheme, placeholder: String) {
        self.theme = theme
        
        self.scrollNode = ASScrollNode()
        self.scrollNode.view.alwaysBounceVertical = true
        
        self.placeholderNode = ASTextNode()
        self.placeholderNode.isUserInteractionEnabled = false
        self.placeholderNode.maximumNumberOfLines = 1
        self.placeholderNode.attributedText = NSAttributedString(string: placeholder, font: Font.regular(15.0), textColor: theme.placeholderTextColor)
        
        self.textFieldNode = TextFieldNode()
        self.textFieldNode.textField.font = Font.regular(15.0)
        self.textFieldNode.textField.textColor = theme.primaryTextColor
        self.textFieldNode.textField.autocorrectionType = .no
        self.textFieldNode.textField.returnKeyType = .done
        switch theme.keyboardColor {
            case .light:
                self.textFieldNode.textField.keyboardAppearance = .default
            case .dark:
                self.textFieldNode.textField.keyboardAppearance = .dark
        }
        
        self.caretIndicatorNode = CaretIndicatorNode()
        self.caretIndicatorNode.isLayerBacked = true
        self.caretIndicatorNode.displayWithoutProcessing = true
        self.caretIndicatorNode.displaysAsynchronously = false
        self.caretIndicatorNode.image = caretIndicatorImage
        
        self.separatorNode = ASDisplayNode()
        self.separatorNode.isLayerBacked = true
        self.separatorNode.backgroundColor = theme.separatorColor
        
        super.init()
        self.addSubnode(self.scrollNode)
        
        self.backgroundColor = theme.backgroundColor
        self.addSubnode(self.separatorNode)
        self.scrollNode.addSubnode(self.placeholderNode)
        self.scrollNode.addSubnode(self.textFieldNode)
        //self.scrollNode.addSubnode(self.caretIndicatorNode)
        self.clipsToBounds = true
        
        self.textFieldNode.textField.delegate = self
        self.textFieldNode.textField.addTarget(self, action: #selector(textFieldChanged(_:)), for: .editingChanged)
        self.textFieldNode.textField.didDeleteBackwardWhileEmpty = { [weak self] in
            if let strongSelf = self {
                if let selectedTokenId = strongSelf.selectedTokenId {
                    strongSelf.deleteToken?(selectedTokenId)
                    strongSelf.updateSelectedTokenId(nil)
                } else if let tokenNode = strongSelf.tokenNodes.last {
                    strongSelf.updateSelectedTokenId(tokenNode.token.id)
                }
            }
        }
        
        self.view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.tapGesture(_:))))
    }
    
    func updateLayout(tokens: [EditableTokenListToken], width: CGFloat, leftInset: CGFloat, rightInset: CGFloat, transition: ContainedViewLayoutTransition) -> CGFloat {
        let validTokens = Set<AnyHashable>(tokens.map { $0.id })
        
        for i in (0 ..< self.tokenNodes.count).reversed() {
            let tokenNode = tokenNodes[i]
            if !validTokens.contains(tokenNode.token.id) {
                self.tokenNodes.remove(at: i)
                if case .immediate = transition {
                    tokenNode.removeFromSupernode()
                } else {
                    tokenNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2, removeOnCompletion: false, completion: { [weak tokenNode] _ in
                        tokenNode?.removeFromSupernode()
                    })
                    tokenNode.layer.animateScale(from: 1.0, to: 0.2, duration: 0.2, removeOnCompletion: false)
                }
            }
        }
        
        if let selectedTokenId = self.selectedTokenId, !validTokens.contains(selectedTokenId) {
            self.selectedTokenId = nil
        }
        
        let sideInset: CGFloat = 4.0 + leftInset
        let verticalInset: CGFloat = 6.0
        
        let placeholderSize = self.placeholderNode.measure(CGSize(width: max(1.0, width - sideInset - sideInset), height: CGFloat.greatestFiniteMagnitude))
        self.placeholderNode.frame = CGRect(origin: CGPoint(x: sideInset + 4.0, y: verticalInset + floor((28.0 - placeholderSize.height) / 2.0)), size: placeholderSize)
        
        transition.updateAlpha(node: self.placeholderNode, alpha: tokens.isEmpty ? 1.0 : 0.0)
        
        var animationDelay = 0.0
        var currentOffset = CGPoint(x: sideInset, y: verticalInset)
        for token in tokens {
            var currentNode: TokenNode?
            for node in self.tokenNodes {
                if node.token.id == token.id {
                    currentNode = node
                    break
                }
            }
            let tokenNode: TokenNode
            var animateIn = false
            if let currentNode = currentNode {
                tokenNode = currentNode
            } else {
                tokenNode = TokenNode(theme: self.theme, token: token, isSelected: self.selectedTokenId != nil && token.id == self.selectedTokenId!)
                self.tokenNodes.append(tokenNode)
                self.scrollNode.addSubnode(tokenNode)
                animateIn = true
            }
            
            let tokenSize = tokenNode.measure(CGSize(width: max(1.0, width - sideInset - sideInset), height: CGFloat.greatestFiniteMagnitude))
            if tokenSize.width + currentOffset.x >= width - sideInset && !currentOffset.x.isEqual(to: sideInset) {
                currentOffset.x = sideInset
                currentOffset.y += tokenSize.height
            }
            let tokenFrame = CGRect(origin: CGPoint(x: currentOffset.x, y: currentOffset.y), size: tokenSize)
            currentOffset.x += ceil(tokenSize.width)
            
            if animateIn {
                tokenNode.frame = tokenFrame
                tokenNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
                tokenNode.layer.animateSpring(from: 0.2 as NSNumber, to: 1.0 as NSNumber, keyPath: "transform.scale", duration: 0.4)
            } else {
                if case .immediate = transition {
                    transition.updateFrame(node: tokenNode, frame: tokenFrame)
                } else {
                    let previousFrame = tokenNode.frame
                    if !previousFrame.origin.y.isEqual(to: tokenFrame.origin.y) && previousFrame.size.width.isEqual(to: tokenFrame.size.width) {
                        let initialStartPosition = CGPoint(x: previousFrame.midX, y: previousFrame.midY)
                        let initialEndPosition = CGPoint(x: -previousFrame.size.width / 2.0, y: previousFrame.midY)
                        let targetStartPosition = CGPoint(x: width + tokenFrame.size.width, y: tokenFrame.midY)
                        let targetEndPosition = CGPoint(x: tokenFrame.midX, y: tokenFrame.midY)
                        tokenNode.frame = tokenFrame
                        
                        let initialAnimation = tokenNode.layer.makeAnimation(from: NSValue(cgPoint: initialStartPosition), to: NSValue(cgPoint: initialEndPosition), keyPath: "position", timingFunction: kCAMediaTimingFunctionEaseInEaseOut, duration: 0.12, mediaTimingFunction: nil, removeOnCompletion: true, additive: false, completion: nil)
                        let targetAnimation = tokenNode.layer.makeAnimation(from: NSValue(cgPoint: targetStartPosition), to: NSValue(cgPoint: targetEndPosition), keyPath: "position", timingFunction: kCAMediaTimingFunctionSpring, duration: 0.2 + animationDelay, mediaTimingFunction: nil, removeOnCompletion: true, additive: false, completion: nil)
                        tokenNode.layer.animateGroup([initialAnimation, targetAnimation], key: "slide")
                        animationDelay += 0.025
                    } else {
                        if !previousFrame.size.width.isEqual(to: tokenFrame.size.width) {
                            tokenNode.frame = tokenFrame
                        } else {
                            let initialStartPosition = CGPoint(x: previousFrame.midX, y: previousFrame.midY)
                            let targetEndPosition = CGPoint(x: tokenFrame.midX, y: tokenFrame.midY)
                            tokenNode.frame = tokenFrame
                            
                            let targetAnimation = tokenNode.layer.makeAnimation(from: NSValue(cgPoint: initialStartPosition), to: NSValue(cgPoint: targetEndPosition), keyPath: "position", timingFunction: kCAMediaTimingFunctionSpring, duration: 0.2 + animationDelay, mediaTimingFunction: nil, removeOnCompletion: true, additive: false, completion: nil)
                            tokenNode.layer.animateGroup([targetAnimation], key: "slide")
                            animationDelay += 0.025
                        }
                    }
                }
            }
        }
        
        if width - currentOffset.x < 200.0 {
            currentOffset.y += 28.0
            currentOffset.x = sideInset
        }
        
        let textNodeFrame = CGRect(origin: CGPoint(x: currentOffset.x + 4.0, y: currentOffset.y + UIScreenPixel), size: CGSize(width: width - currentOffset.x - sideInset - 8.0, height: 28.0))
        let caretNodeFrame = CGRect(origin: CGPoint(x: textNodeFrame.minX, y: textNodeFrame.minY + 4.0 - UIScreenPixel), size: CGSize(width: 2.0, height: 19.0 + UIScreenPixel))
        if case .immediate = transition {
            transition.updateFrame(node: self.textFieldNode, frame: textNodeFrame)
            transition.updateFrame(node: self.caretIndicatorNode, frame: caretNodeFrame)
        } else {
            let previousFrame = self.textFieldNode.frame
            self.textFieldNode.frame = textNodeFrame
            self.textFieldNode.layer.animateFrame(from: previousFrame, to: textNodeFrame, duration: 0.2 + animationDelay, timingFunction: kCAMediaTimingFunctionSpring)
            
            let previousCaretFrame = self.caretIndicatorNode.frame
            self.caretIndicatorNode.frame = caretNodeFrame
            self.caretIndicatorNode.layer.animateFrame(from: previousCaretFrame, to: caretNodeFrame, duration: 0.2 + animationDelay, timingFunction: kCAMediaTimingFunctionSpring)
        }
        
        let previousContentHeight = self.scrollNode.view.contentSize.height
        let contentHeight = currentOffset.y + 29.0 + verticalInset
        let nodeHeight = min(contentHeight, 110.0)
        
        let separatorHeight = UIScreenPixel
        transition.updateFrame(node: self.separatorNode, frame: CGRect(origin: CGPoint(x: 0.0, y: nodeHeight - separatorHeight), size: CGSize(width: width, height: separatorHeight)))
        transition.updateFrame(node: self.scrollNode, frame: CGRect(origin: CGPoint(), size: CGSize(width: width, height: nodeHeight)))
        
        if !abs(previousContentHeight - contentHeight).isLess(than: CGFloat.ulpOfOne) {
            let contentOffset = CGPoint(x: 0, y: max(0, contentHeight - nodeHeight))
            if case .immediate = transition {
                self.scrollNode.view.contentOffset = contentOffset
            }
            else {
                UIView.animate(withDuration: 0.2) {
                    self.scrollNode.view.contentOffset = contentOffset
                }
            }
        }
        self.scrollNode.view.contentSize = CGSize(width: width, height: contentHeight)
        
        return nodeHeight
    }
    
    @objc func textFieldChanged(_ textField: UITextField) {
        self.placeholderNode.isHidden = textField.text != nil && !textField.text!.isEmpty
        self.updateSelectedTokenId(nil)
        self.textUpdated?(textField.text ?? "")
    }
    
    func textFieldDidBeginEditing(_ textField: UITextField) {
        /*if self.caretIndicatorNode.supernode == self {
            self.caretIndicatorNode.removeFromSupernode()
        }*/
    }
    
    func textFieldDidEndEditing(_ textField: UITextField) {
        /*if self.caretIndicatorNode.supernode != self.scrollNode {
            self.scrollNode.addSubnode(self.caretIndicatorNode)
        }*/
    }
    
    func setText(_ text: String) {
        self.textFieldNode.textField.text = text
        self.textFieldChanged(self.textFieldNode.textField)
    }
    
    private func updateSelectedTokenId(_ id: AnyHashable?) {
        self.selectedTokenId = id
        for tokenNode in self.tokenNodes {
            tokenNode.isSelected = id == tokenNode.token.id
        }
        if id != nil {
            self.textFieldNode.textField.becomeFirstResponder()
        }
    }
    
    @objc private func tapGesture(_ recognizer: UITapGestureRecognizer) {
        if case .ended = recognizer.state {
            let point = recognizer.location(in: self.view)
            for tokenNode in self.tokenNodes {
                if tokenNode.frame.contains(point) {
                    self.updateSelectedTokenId(tokenNode.token.id)
                    break
                }
            }
        }
    }
}
