//
//  MFDrawingLayer.h 鈥?閫忔槑缁樺埗灞傦紙ESP锛?//
//  鎸傚湪 DrawingWindow 鐨?MFOverlayView 涓婏紝姣忓抚锛?//    鈶?璇荤浉鏈?鈫?鈶?璇诲疄浣?鐗╄祫 鈫?鈶?鎶曞奖 鈫?鈶?鐢?ImGui DrawList 鐢诲嚭鏉?//
//  缁樺埗鍐呭瀵圭収銆婄櫧绫抽キ琛ュ厖鍒嗘瀽銆嬄? 鐨勮彍鍗曢」锛?//    浜烘満鏄剧ず / 鍚嶅瓧 / 澶寸敳 / 琛€閲?/ 璺濈 / 闃熶紞 / 灏勭嚎 / 鎵嬫寔 / 楠ㄩ
//    鐗╄祫 / 鐩掑瓙 / 鐗╄祫鍚嶅瓧 / 缁熻绐楀彛
//
//  鈿狅笍 鍋忕Щ鏈牎鍑嗗墠锛歳eader 璇讳笉鍒扮浉鏈哄氨浼氭暣甯ц烦杩囷紝涓嶄細鐢婚敊涓滆タ銆?//     鏍″噯鍏ュ彛瑙?Game/Offsets.h + MFGameReader 鐨?rootObjectBase / entityArrayBase / lootArrayBase銆?//
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class MFOverlayView;

NS_ASSUME_NONNULL_BEGIN

@interface MFDrawingLayer : NSObject

@property (nonatomic, weak, nullable) MFOverlayView *overlay;

/// 鍏ㄥ眬寮€鍏筹紙涓庤彍鍗曠殑銆屾€诲紑鍏炽€嶈仈鍔級
+ (void)setEnabled:(BOOL)enabled;
+ (BOOL)enabled;

/// 鏈抚缁熻锛堜緵鑿滃崟/鏃ュ織鏄剧ず锛?@property (nonatomic, readonly) NSUInteger lastEntityCount;
@property (nonatomic, readonly) NSUInteger lastLootCount;
@property (nonatomic, readonly) BOOL lastCameraOK;

/// 璇婃柇锛氫竴甯х殑瀹屾暣璇绘暟杞偍锛堜緵鐪熸満鏍″噯鐪嬪亸绉诲涓嶅锛?- (NSString *)dumpFrameWithSize:(CGSize)size;

@end

NS_ASSUME_NONNULL_END
