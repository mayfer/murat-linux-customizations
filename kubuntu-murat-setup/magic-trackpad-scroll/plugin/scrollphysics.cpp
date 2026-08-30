/*
    SPDX-License-Identifier: GPL-2.0-or-later
*/
#include "scrollphysics.h"

#include <algorithm>
#include <cmath>

namespace MuratMagicScroll
{

double responseGain(double speed, const ResponseConfig &config)
{
    const double safeSpeed = std::max(0.0, speed);
    const double curveVelocity = std::max(1.0, config.curveVelocity);
    const double exponent = std::max(0.1, config.curveExponent);
    const double ratio = safeSpeed / (safeSpeed + curveVelocity);
    const double shaped = std::pow(ratio, exponent);
    return config.lowSpeedGain + (config.highSpeedGain - config.lowSpeedGain) * shaped;
}

double timeConstantSeconds(double speed, const MomentumConfig &config)
{
    const double safeSpeed = std::max(0.0, speed);
    const double scale = std::max(1.0, config.timeConstantVelocity);
    const double ratio = safeSpeed / (safeSpeed + scale);
    const double milliseconds = config.minimumTimeConstantMs
        + (config.maximumTimeConstantMs - config.minimumTimeConstantMs) * ratio;
    return std::max(1.0, milliseconds) / 1000.0;
}

KineticStep advanceKinetic(double velocity, double timeConstant, double elapsedSeconds, double stopVelocity)
{
    if (!std::isfinite(velocity) || !std::isfinite(timeConstant) || !std::isfinite(elapsedSeconds)
        || timeConstant <= 0.0 || elapsedSeconds <= 0.0 || std::abs(velocity) <= stopVelocity) {
        return {};
    }

    const double decay = std::exp(-elapsedSeconds / timeConstant);
    const double nextVelocity = velocity * decay;
    const double delta = velocity * timeConstant * (1.0 - decay);
    const bool finished = std::abs(nextVelocity) <= stopVelocity;
    return {
        .delta = delta,
        .velocity = finished ? 0.0 : nextVelocity,
        .finished = finished,
    };
}

} // namespace MuratMagicScroll
