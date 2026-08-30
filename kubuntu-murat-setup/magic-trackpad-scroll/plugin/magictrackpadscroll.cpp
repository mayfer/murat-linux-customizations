/*
    SPDX-License-Identifier: GPL-2.0-or-later
*/
#include "magictrackpadscroll.h"

#include "core/inputdevice.h"
#include "effect/effecthandler.h"

#include <KConfigGroup>
#include <KSharedConfig>
#include <QLoggingCategory>
#include <QMetaObject>

#include <algorithm>
#include <cmath>

Q_LOGGING_CATEGORY(KWIN_MAGIC_SCROLL, "kwin.effect.murat_magic_trackpad_scroll")

namespace MuratMagicScroll
{

using namespace std::chrono_literals;

namespace
{
constexpr auto ConfigFile = "magic-trackpad-scrollrc";

double millisecondsBetween(std::chrono::microseconds newer, std::chrono::microseconds older)
{
    return std::chrono::duration<double, std::milli>(newer - older).count();
}

double clampFinite(double value, double minimum, double maximum, double fallback)
{
    return std::isfinite(value) ? std::clamp(value, minimum, maximum) : fallback;
}
}

MagicTrackpadScrollEffect::MagicTrackpadScrollEffect()
    : KWin::InputEventFilter(KWin::InputFilterOrder::InputMethod)
{
    reconfigure(ReconfigureAll);
    KWin::input()->installInputEventFilter(this);

    connect(KWin::input(), &KWin::InputRedirection::deviceRemoved, this, [this](KWin::InputDevice *device) {
        for (auto &axis : m_axes) {
            if (axis.context.device == device) {
                resetGesture(axis);
            }
        }
    });

    qCInfo(KWIN_MAGIC_SCROLL) << "loaded for device" << m_vendor << m_product;
}

MagicTrackpadScrollEffect::~MagicTrackpadScrollEffect()
{
    KWin::input()->uninstallInputEventFilter(this);
}

bool MagicTrackpadScrollEffect::supported()
{
    return KWin::input() != nullptr;
}

bool MagicTrackpadScrollEffect::enabledByDefault()
{
    return false;
}

bool MagicTrackpadScrollEffect::isActive() const
{
    return hasMomentum();
}

bool MagicTrackpadScrollEffect::blocksDirectScanout() const
{
    return false;
}

void MagicTrackpadScrollEffect::reconfigure(ReconfigureFlags flags)
{
    Q_UNUSED(flags)

    const auto config = KSharedConfig::openConfig(QString::fromLatin1(ConfigFile));
    const KConfigGroup device(config, QStringLiteral("Device"));
    const KConfigGroup response(config, QStringLiteral("Response"));
    const KConfigGroup momentum(config, QStringLiteral("Momentum"));
    const KConfigGroup behaviour(config, QStringLiteral("Behaviour"));

    m_vendor = device.readEntry("Vendor", 1452u);
    m_product = device.readEntry("Product", 613u);

    m_response.lowSpeedGain = clampFinite(response.readEntry("LowSpeedGain", 0.50), 0.05, 5.0, 0.50);
    m_response.highSpeedGain = clampFinite(response.readEntry("HighSpeedGain", 1.35), 0.05, 5.0, 1.35);
    if (m_response.highSpeedGain < m_response.lowSpeedGain) {
        std::swap(m_response.highSpeedGain, m_response.lowSpeedGain);
    }
    m_response.curveVelocity = clampFinite(response.readEntry("CurveVelocity", 950.0), 1.0, 50000.0, 950.0);
    m_response.curveExponent = clampFinite(response.readEntry("CurveExponent", 1.30), 0.1, 8.0, 1.30);
    m_speedSmoothingMs = clampFinite(response.readEntry("SpeedSmoothingMs", 28.0), 1.0, 500.0, 28.0);

    m_momentumEnabled = momentum.readEntry("Enabled", true);
    m_velocityWindowMs = clampFinite(momentum.readEntry("VelocityWindowMs", 80.0), 10.0, 500.0, 80.0);
    m_velocityWeightMs = clampFinite(momentum.readEntry("VelocityWeightMs", 38.0), 1.0, 500.0, 38.0);
    m_releaseStaleMs = clampFinite(momentum.readEntry("ReleaseStaleMs", 70.0), 1.0, 500.0, 70.0);
    m_launchScale = clampFinite(momentum.readEntry("LaunchScale", 0.82), 0.0, 3.0, 0.82);
    m_noiseFloor = clampFinite(momentum.readEntry("NoiseFloor", 6.0), 0.0, 1000.0, 6.0);
    m_maximumVelocity = clampFinite(momentum.readEntry("MaximumVelocity", 5000.0), 10.0, 100000.0, 5000.0);
    m_momentum.minimumTimeConstantMs = clampFinite(momentum.readEntry("MinimumTimeConstantMs", 280.0), 10.0, 5000.0, 280.0);
    m_momentum.maximumTimeConstantMs = clampFinite(momentum.readEntry("MaximumTimeConstantMs", 620.0), 10.0, 5000.0, 620.0);
    if (m_momentum.maximumTimeConstantMs < m_momentum.minimumTimeConstantMs) {
        std::swap(m_momentum.maximumTimeConstantMs, m_momentum.minimumTimeConstantMs);
    }
    m_momentum.timeConstantVelocity = clampFinite(momentum.readEntry("TimeConstantVelocity", 1600.0), 1.0, 100000.0, 1600.0);
    m_momentum.stopVelocity = clampFinite(momentum.readEntry("StopVelocity", 1.5), 0.01, 1000.0, 1.5);
    m_maximumFrameMs = clampFinite(momentum.readEntry("MaximumFrameMs", 50.0), 5.0, 250.0, 50.0);

    m_cancelOnPointerMotion = behaviour.readEntry("CancelOnPointerMotion", true);
    m_cancelOnKey = behaviour.readEntry("CancelOnKey", true);
    m_cancelOnButton = behaviour.readEntry("CancelOnButton", true);
    m_diagnostics = behaviour.readEntry("Diagnostics", true);

    const QString source = behaviour.readEntry("OutputSource", QStringLiteral("continuous"));
    if (source.compare(QStringLiteral("continuous"), Qt::CaseInsensitive) != 0) {
        qCWarning(KWIN_MAGIC_SCROLL) << "only OutputSource=continuous is currently supported; using continuous";
    }
}

bool MagicTrackpadScrollEffect::matchesDevice(const KWin::PointerAxisEvent *event) const
{
    return event && event->device && event->source == KWin::PointerAxisSource::Finger
        && event->device->isTouchpad() && event->device->vendor() == m_vendor && event->device->product() == m_product;
}

double MagicTrackpadScrollEffect::transformDelta(AxisState &state, double delta, std::chrono::microseconds time)
{
    double elapsedSeconds = 0.0;
    if (state.hasLastEvent) {
        const double elapsedMs = millisecondsBetween(time, state.lastEventTime);
        if (elapsedMs > 0.0 && elapsedMs <= 100.0) {
            elapsedSeconds = elapsedMs / 1000.0;
            const double instantaneousSpeed = std::abs(delta) / elapsedSeconds;
            const double alpha = 1.0 - std::exp(-elapsedMs / m_speedSmoothingMs);
            state.smoothedRawSpeed += alpha * (instantaneousSpeed - state.smoothedRawSpeed);
            state.peakRawSpeed = std::max(state.peakRawSpeed, instantaneousSpeed);
        } else {
            state.smoothedRawSpeed = 0.0;
            state.samples.clear();
        }
    }

    const double gain = responseGain(state.smoothedRawSpeed, m_response);
    const double output = delta * gain;
    if (elapsedSeconds > 0.0) {
        recordVelocity(state, output, elapsedSeconds, time);
    }

    state.hasLastEvent = true;
    state.lastEventTime = time;
    state.totalInput += delta;
    state.totalOutput += output;
    return output;
}

void MagicTrackpadScrollEffect::recordVelocity(AxisState &state, double delta, double elapsedSeconds, std::chrono::microseconds time)
{
    if (elapsedSeconds <= 0.0 || elapsedSeconds > 0.100) {
        return;
    }
    state.samples.push_back({time, delta / elapsedSeconds});
    const auto oldest = time - std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::duration<double, std::milli>(m_velocityWindowMs));
    while (!state.samples.empty() && state.samples.front().time < oldest) {
        state.samples.pop_front();
    }
}

double MagicTrackpadScrollEffect::releaseVelocity(AxisState &state, std::chrono::microseconds time)
{
    if (!state.hasLastEvent || millisecondsBetween(time, state.lastEventTime) > m_releaseStaleMs) {
        return 0.0;
    }

    double weightedVelocity = 0.0;
    double totalWeight = 0.0;
    for (const auto &sample : state.samples) {
        const double ageMs = std::max(0.0, millisecondsBetween(time, sample.time));
        if (ageMs > m_velocityWindowMs) {
            continue;
        }
        const double weight = std::exp(-ageMs / m_velocityWeightMs);
        weightedVelocity += sample.velocity * weight;
        totalWeight += weight;
    }
    return totalWeight > 0.0 ? weightedVelocity / totalWeight : 0.0;
}

bool MagicTrackpadScrollEffect::beginMomentum(AxisState &state, std::chrono::microseconds time, Qt::Orientation orientation)
{
    double velocity = releaseVelocity(state, time) * m_launchScale;
    velocity = std::clamp(velocity, -m_maximumVelocity, m_maximumVelocity);
    const double speed = std::abs(velocity);

    if (m_diagnostics) {
        qCInfo(KWIN_MAGIC_SCROLL).nospace()
            << (orientation == Qt::Horizontal ? "horizontal" : "vertical")
            << " release: input=" << state.totalInput << " output=" << state.totalOutput
            << " peakRaw=" << state.peakRawSpeed << "/s launch=" << velocity << "/s";
    }

    if (!m_momentumEnabled || speed <= m_noiseFloor) {
        return false;
    }

    state.kinetic = true;
    state.kineticVelocity = velocity;
    state.timeConstant = timeConstantSeconds(speed, m_momentum);
    state.pendingStop = false;
    m_lastFrameTime = std::chrono::duration_cast<std::chrono::milliseconds>(time);
    KWin::effects->addRepaintFull();
    return true;
}

bool MagicTrackpadScrollEffect::pointerAxis(KWin::PointerAxisEvent *event)
{
    if (m_syntheticDispatch || !matchesDevice(event)) {
        return false;
    }

    auto &state = m_axes[axisIndex(event->orientation)];
    state.context = {
        .device = event->device,
        .position = event->position,
        .buttons = event->buttons,
        .modifiers = event->modifiers,
        .shortcutModifiers = event->modifiersRelevantForGlobalShortcuts,
        .inverted = event->inverted,
    };

    if (qFuzzyIsNull(event->delta)) {
        if (beginMomentum(state, event->timestamp, event->orientation)) {
            return true;
        }
        event->source = KWin::PointerAxisSource::Continuous;
        event->deltaV120 = 0;
        resetGesture(state);
        return false;
    }

    if (state.kinetic) {
        state.kinetic = false;
        state.pendingStop = false;
        m_lastFrameTime.reset();
    }
    state.sequenceOpen = true;
    event->delta = transformDelta(state, event->delta, event->timestamp);
    event->deltaV120 = 0;
    event->source = KWin::PointerAxisSource::Continuous;
    return false;
}

bool MagicTrackpadScrollEffect::pointerMotion(KWin::PointerMotionEvent *event)
{
    Q_UNUSED(event)
    if (m_cancelOnPointerMotion && hasMomentum()) {
        interruptMomentum(true);
    }
    return false;
}

bool MagicTrackpadScrollEffect::pointerButton(KWin::PointerButtonEvent *event)
{
    Q_UNUSED(event)
    if (m_cancelOnButton && hasMomentum()) {
        interruptMomentum(true);
    }
    return false;
}

bool MagicTrackpadScrollEffect::keyboardKey(KWin::KeyboardKeyEvent *event)
{
    Q_UNUSED(event)
    if (m_cancelOnKey && hasMomentum()) {
        interruptMomentum(true);
    }
    return false;
}

bool MagicTrackpadScrollEffect::holdGestureBegin(KWin::PointerHoldGestureBeginEvent *event)
{
    Q_UNUSED(event)
    if (hasMomentum()) {
        interruptMomentum(true);
    }
    return false;
}

void MagicTrackpadScrollEffect::interruptMomentum(bool sendStops)
{
    bool needsStop = false;
    for (auto &axis : m_axes) {
        if (!axis.kinetic) {
            continue;
        }
        axis.kinetic = false;
        axis.kineticVelocity = 0.0;
        if (sendStops && axis.sequenceOpen) {
            axis.pendingStop = true;
            needsStop = true;
        }
    }
    m_lastFrameTime.reset();
    if (needsStop) {
        queueStops();
    }
}

void MagicTrackpadScrollEffect::queueStops()
{
    if (m_stopFlushQueued) {
        return;
    }
    m_stopFlushQueued = true;
    QMetaObject::invokeMethod(this, &MagicTrackpadScrollEffect::flushStops, Qt::QueuedConnection);
}

void MagicTrackpadScrollEffect::flushStops()
{
    m_stopFlushQueued = false;
    bool emitted = false;
    const auto now = std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now().time_since_epoch());
    for (std::size_t i = 0; i < m_axes.size(); ++i) {
        auto &axis = m_axes[i];
        if (!axis.pendingStop) {
            continue;
        }
        axis.pendingStop = false;
        emitSyntheticAxis(i, 0.0, now);
        emitted = true;
        resetGesture(axis);
    }
    if (emitted) {
        emitSyntheticFrame();
    }
}

void MagicTrackpadScrollEffect::emitSyntheticAxis(std::size_t index, double delta, std::chrono::microseconds time)
{
    auto &state = m_axes[index];
    if (!state.context.device) {
        return;
    }

    KWin::PointerAxisEvent event{
        .device = state.context.device,
        .position = state.context.position,
        .delta = delta,
        .deltaV120 = 0,
        .orientation = orientationFor(index),
        .source = KWin::PointerAxisSource::Continuous,
        .buttons = state.context.buttons,
        .modifiers = state.context.modifiers,
        .modifiersRelevantForGlobalShortcuts = state.context.shortcutModifiers,
        .inverted = state.context.inverted,
        .timestamp = time,
    };

    m_syntheticDispatch = true;
    KWin::input()->processFilters(&KWin::InputEventFilter::pointerAxis, &event);
    m_syntheticDispatch = false;
}

void MagicTrackpadScrollEffect::emitSyntheticFrame()
{
    m_syntheticDispatch = true;
    KWin::input()->processFilters(&KWin::InputEventFilter::pointerFrame);
    m_syntheticDispatch = false;
}

void MagicTrackpadScrollEffect::prePaintScreen(KWin::ScreenPrePaintData &data, std::chrono::milliseconds presentTime)
{
    KWin::Effect::prePaintScreen(data, presentTime);
    if (!hasMomentum()) {
        return;
    }

    if (!m_lastFrameTime || presentTime <= *m_lastFrameTime) {
        m_lastFrameTime = presentTime;
        KWin::effects->addRepaintFull();
        return;
    }

    const double elapsedMs = std::min<double>((presentTime - *m_lastFrameTime).count(), m_maximumFrameMs);
    m_lastFrameTime = presentTime;
    const double elapsedSeconds = elapsedMs / 1000.0;
    const auto timestamp = std::chrono::duration_cast<std::chrono::microseconds>(presentTime);
    bool emitted = false;

    for (std::size_t i = 0; i < m_axes.size(); ++i) {
        auto &axis = m_axes[i];
        if (!axis.kinetic) {
            continue;
        }

        const auto step = advanceKinetic(axis.kineticVelocity, axis.timeConstant, elapsedSeconds, m_momentum.stopVelocity);
        if (!qFuzzyIsNull(step.delta)) {
            emitSyntheticAxis(i, step.delta, timestamp);
            emitted = true;
        }
        axis.kineticVelocity = step.velocity;
        if (step.finished) {
            axis.kinetic = false;
            emitSyntheticAxis(i, 0.0, timestamp);
            emitted = true;
            resetGesture(axis);
        }
    }

    if (emitted) {
        emitSyntheticFrame();
    }
    if (hasMomentum()) {
        KWin::effects->addRepaintFull();
    } else {
        m_lastFrameTime.reset();
    }
}

bool MagicTrackpadScrollEffect::hasMomentum() const
{
    return std::any_of(m_axes.cbegin(), m_axes.cend(), [](const AxisState &axis) {
        return axis.kinetic;
    });
}

void MagicTrackpadScrollEffect::resetGesture(AxisState &state)
{
    state = AxisState{};
}

} // namespace MuratMagicScroll
