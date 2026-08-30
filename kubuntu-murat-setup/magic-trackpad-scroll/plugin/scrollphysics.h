/*
    SPDX-License-Identifier: GPL-2.0-or-later
*/
#pragma once

namespace MuratMagicScroll
{

struct ResponseConfig
{
    double lowSpeedGain = 0.50;
    double highSpeedGain = 1.35;
    double curveVelocity = 950.0;
    double curveExponent = 1.30;
};

struct MomentumConfig
{
    double minimumTimeConstantMs = 280.0;
    double maximumTimeConstantMs = 620.0;
    double timeConstantVelocity = 1600.0;
    double stopVelocity = 1.5;
};

struct KineticStep
{
    double delta = 0.0;
    double velocity = 0.0;
    bool finished = true;
};

double responseGain(double speed, const ResponseConfig &config);
double timeConstantSeconds(double speed, const MomentumConfig &config);
KineticStep advanceKinetic(double velocity, double timeConstant, double elapsedSeconds, double stopVelocity);

} // namespace MuratMagicScroll
