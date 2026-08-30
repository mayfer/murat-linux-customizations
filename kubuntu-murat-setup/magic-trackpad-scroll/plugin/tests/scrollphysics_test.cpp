/*
    SPDX-License-Identifier: GPL-2.0-or-later
*/
#include "scrollphysics.h"

#include <cmath>
#include <iostream>

using namespace MuratMagicScroll;

int main()
{
    const auto check = [](bool condition, const char *message) {
        if (!condition) {
            std::cerr << "FAILED: " << message << '\n';
            return false;
        }
        return true;
    };

    const ResponseConfig response;
    if (!check(std::abs(responseGain(0.0, response) - response.lowSpeedGain) < 1e-12, "zero-speed gain")) return 1;
    if (!check(responseGain(100.0, response) < responseGain(1000.0, response), "low-to-medium gain monotonicity")) return 1;
    if (!check(responseGain(1000.0, response) < responseGain(10000.0, response), "medium-to-high gain monotonicity")) return 1;
    if (!check(responseGain(1.0e12, response) < response.highSpeedGain + 1e-6, "high-speed gain bound")) return 1;

    const MomentumConfig momentum;
    if (!check(timeConstantSeconds(100.0, momentum) < timeConstantSeconds(3000.0, momentum), "time-constant monotonicity")) return 1;

    double velocity = 1000.0;
    double distance = 0.0;
    const double tau = 0.5;
    for (int i = 0; i < 10000 && velocity != 0.0; ++i) {
        const auto step = advanceKinetic(velocity, tau, 0.001, momentum.stopVelocity);
        distance += step.delta;
        velocity = step.velocity;
    }
    if (!check(distance > 490.0 && distance < 501.0, "integrated exponential distance")) return 1;

    const auto stopped = advanceKinetic(1.0, tau, 0.016, momentum.stopVelocity);
    if (!check(stopped.finished && stopped.delta == 0.0 && stopped.velocity == 0.0, "sub-threshold stop")) return 1;
    return 0;
}
