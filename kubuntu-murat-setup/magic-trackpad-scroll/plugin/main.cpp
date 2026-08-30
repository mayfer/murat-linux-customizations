/*
    SPDX-License-Identifier: GPL-2.0-or-later
*/
#include "magictrackpadscroll.h"

#include "effect/effect.h"

using MuratMagicScroll::MagicTrackpadScrollEffect;

KWIN_EFFECT_FACTORY_SUPPORTED_ENABLED(
    MagicTrackpadScrollEffect,
    "metadata.json",
    return MagicTrackpadScrollEffect::supported();,
    return MagicTrackpadScrollEffect::enabledByDefault();)

#include "main.moc"
