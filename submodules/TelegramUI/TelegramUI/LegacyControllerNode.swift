import Foundation
import UIKit
import AsyncDisplayKit
import Display

final class LegacyControllerNode: ASDisplayNode {
    private var containerLayout: ContainerViewLayout?
    
    var controllerView: UIView? {
        didSet {
            if let controllerView = self.controllerView, let containerLayout = self.containerLayout {
                controllerView.frame = CGRect(origin: CGPoint(), size: containerLayout.size)
            }
        }
    }
    
    override init() {
        super.init()
        
        self.setViewBlock({
            return UITracingLayerView()
        })
        
        self.clipsToBounds = true
    }
    
    func containerLayoutUpdated(_ layout: ContainerViewLayout, navigationBarHeight: CGFloat, transition: ContainedViewLayoutTransition) {
        self.containerLayout = layout
        if let controllerView = self.controllerView {
            controllerView.frame = CGRect(origin: CGPoint(), size: layout.size)
        }
    }
    
    func animateModalIn(completion: @escaping () -> Void) {
        self.layer.animatePosition(from: CGPoint(x: 0.0, y: self.layer.bounds.size.height), to: CGPoint(), duration: 0.5, timingFunction: kCAMediaTimingFunctionSpring, additive: true, completion: { _ in
            completion()
        })
    }
    
    func animateModalOut(completion: @escaping () -> Void) {
        self.layer.animatePosition(from: CGPoint(), to: CGPoint(x: 0.0, y: self.layer.bounds.size.height), duration: 0.2, timingFunction: kCAMediaTimingFunctionEaseInEaseOut, removeOnCompletion: false, additive: true, completion: { _ in
            completion()
        })
    }
}
