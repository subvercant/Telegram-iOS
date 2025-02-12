import Foundation
import UIKit
import Display
import AsyncDisplayKit
import LegacyComponents

private let transitionDuration = 0.2
private let animationKey = "animation"

class ChatTitleActivityIndicatorNode: ASDisplayNode {
    var duration: CFTimeInterval {
        return 0.0
    }
    
    var timingFunction: CAMediaTimingFunction {
        return CAMediaTimingFunction(name: kCAMediaTimingFunctionLinear)
    }
    
    var color: UIColor? {
        didSet {
            self.setNeedsDisplay()
        }
    }
    
    var progress: CGFloat = 0.0 {
        didSet {
            self.setNeedsDisplay()
        }
    }
    
    init(color: UIColor) {
        self.color = color
        
        super.init()
        
        self.isLayerBacked = true
        self.displaysAsynchronously = true
        self.isOpaque = false
    }
    
    deinit {
        self.stopAnimation()
    }
    
    private func startAnimation() {
        self.stopAnimation()
        
        let animation = POPBasicAnimation()
        animation.property = POPAnimatableProperty.property(withName: "progress", initializer: { property in
            property?.readBlock = { node, values in
                values?.pointee = (node as! ChatTitleActivityIndicatorNode).progress
            }
            property?.writeBlock = { node, values in
                (node as! ChatTitleActivityIndicatorNode).progress = values!.pointee
            }
            property?.threshold = 0.01
        }) as? POPAnimatableProperty
        animation.fromValue = 0.0 as NSNumber
        animation.toValue = 1.0 as NSNumber
        animation.timingFunction = self.timingFunction
        animation.duration = self.duration
        animation.repeatForever = true
        
        self.pop_add(animation, forKey: animationKey)
    }
    
    private func stopAnimation() {
        self.pop_removeAnimation(forKey: animationKey)
    }
    
    override func didEnterHierarchy() {
        super.didEnterHierarchy()
        self.startAnimation()
    }
    
    override func didExitHierarchy() {
        super.didExitHierarchy()
        self.stopAnimation()
    }
}

class ChatTitleActivityContentNode: ASDisplayNode {
    let textNode: ImmediateTextNode
    
    init(text: NSAttributedString) {
        self.textNode = ImmediateTextNode()
        self.textNode.displaysAsynchronously = false
        self.textNode.maximumNumberOfLines = 1
        self.textNode.isOpaque = false
        
        super.init()
        
        self.addSubnode(self.textNode)
        
        self.textNode.attributedText = text
    }
    
    func animateOut(to: ChatTitleActivityNodeState, style: ChatTitleActivityAnimationStyle, completion: @escaping () -> Void) {
        self.layer.animateAlpha(from: 1.0, to: 0.0, duration: transitionDuration, removeOnCompletion: false, completion: { _ in
            completion()
        })
        
        if case .slide = style {
            self.layer.animatePosition(from: CGPoint(), to: CGPoint(x: 0.0, y: 14.0), duration: transitionDuration, additive: true)
        }
    }
        
    func animateIn(from: ChatTitleActivityNodeState, style: ChatTitleActivityAnimationStyle) {
        self.layer.animateAlpha(from: 0.0, to: 1.0, duration: transitionDuration)
        
        if case .slide = style {
            self.layer.animatePosition(from: CGPoint(x: 0.0, y: -14.0), to: CGPoint(), duration: transitionDuration, additive: true)
        }
    }
    
    func updateLayout(_ constrainedSize: CGSize, alignment: NSTextAlignment) -> CGSize {
        let size = self.textNode.updateLayout(constrainedSize)
        self.textNode.bounds = CGRect(origin: CGPoint(), size: size)
        if case .center = alignment {
            self.textNode.position = CGPoint(x: 0.0, y: size.height / 2.0)
        } else {
            self.textNode.position = CGPoint(x: size.width / 2.0, y: size.height / 2.0)
        }
        return size
    }
}
