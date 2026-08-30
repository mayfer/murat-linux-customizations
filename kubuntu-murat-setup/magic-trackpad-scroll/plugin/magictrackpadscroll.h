/*
    SPDX-License-Identifier: GPL-2.0-or-later
*/
#pragma once

#include "effect/effect.h"
#include "input.h"
#include "input_event.h"
#include "scrollphysics.h"

#include <QPointer>

#include <array>
#include <chrono>
#include <deque>
#include <optional>

namespace MuratMagicScroll
{

class MagicTrackpadScrollEffect final
    : public KWin::Effect
    , public KWin::InputEventFilter
{
    Q_OBJECT

public:
    MagicTrackpadScrollEffect();
    ~MagicTrackpadScrollEffect() override;

    static bool supported();
    static bool enabledByDefault();

    bool isActive() const override;
    bool blocksDirectScanout() const override;
    void reconfigure(ReconfigureFlags flags) override;
    void prePaintScreen(KWin::ScreenPrePaintData &data, std::chrono::milliseconds presentTime) override;

    bool pointerAxis(KWin::PointerAxisEvent *event) override;
    bool pointerMotion(KWin::PointerMotionEvent *event) override;
    bool pointerButton(KWin::PointerButtonEvent *event) override;
    bool keyboardKey(KWin::KeyboardKeyEvent *event) override;
    bool holdGestureBegin(KWin::PointerHoldGestureBeginEvent *event) override;

private:
    struct VelocitySample
    {
        std::chrono::microseconds time;
        double velocity = 0.0;
    };

    struct EventContext
    {
        QPointer<KWin::InputDevice> device;
        QPointF position;
        Qt::MouseButtons buttons;
        Qt::KeyboardModifiers modifiers;
        Qt::KeyboardModifiers shortcutModifiers;
        bool inverted = false;
    };

    struct AxisState
    {
        bool sequenceOpen = false;
        bool kinetic = false;
        bool pendingStop = false;
        bool hasLastEvent = false;
        std::chrono::microseconds lastEventTime{};
        double smoothedRawSpeed = 0.0;
        double kineticVelocity = 0.0;
        double timeConstant = 0.0;
        double totalInput = 0.0;
        double totalOutput = 0.0;
        double peakRawSpeed = 0.0;
        std::deque<VelocitySample> samples;
        EventContext context;
    };

    static constexpr std::size_t axisIndex(Qt::Orientation orientation)
    {
        return orientation == Qt::Horizontal ? 0 : 1;
    }

    static constexpr Qt::Orientation orientationFor(std::size_t index)
    {
        return index == 0 ? Qt::Horizontal : Qt::Vertical;
    }

    bool matchesDevice(const KWin::PointerAxisEvent *event) const;
    double transformDelta(AxisState &state, double delta, std::chrono::microseconds time);
    void recordVelocity(AxisState &state, double delta, double elapsedSeconds, std::chrono::microseconds time);
    double releaseVelocity(AxisState &state, std::chrono::microseconds time);
    bool beginMomentum(AxisState &state, std::chrono::microseconds time, Qt::Orientation orientation);
    void interruptMomentum(bool sendStops);
    void queueStops();
    void flushStops();
    void emitSyntheticAxis(std::size_t index, double delta, std::chrono::microseconds time);
    void emitSyntheticFrame();
    bool hasMomentum() const;
    void resetGesture(AxisState &state);

    std::array<AxisState, 2> m_axes;
    ResponseConfig m_response;
    MomentumConfig m_momentum;
    std::optional<std::chrono::milliseconds> m_lastFrameTime;
    bool m_syntheticDispatch = false;
    bool m_stopFlushQueued = false;
    bool m_momentumEnabled = true;
    bool m_cancelOnPointerMotion = true;
    bool m_cancelOnKey = true;
    bool m_cancelOnButton = true;
    bool m_diagnostics = true;
    quint32 m_vendor = 1452;
    quint32 m_product = 613;
    double m_speedSmoothingMs = 28.0;
    double m_velocityWindowMs = 80.0;
    double m_velocityWeightMs = 38.0;
    double m_releaseStaleMs = 70.0;
    double m_launchScale = 0.82;
    double m_noiseFloor = 6.0;
    double m_maximumVelocity = 5000.0;
    double m_maximumFrameMs = 50.0;
};

} // namespace MuratMagicScroll
