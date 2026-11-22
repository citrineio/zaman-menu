.pragma library

function gb(bytes) {
    return (bytes / 1000000000).toFixed(1) + " GB";
}

function drive(device) {
    var volumes = device.volumes || [];
    var free = 0;
    var used = 0;
    var total = 0;
    var measured = 0;
    for (var i = 0; i < volumes.length; ++i) {
        var volume = volumes[i];
        if (!volume.mountpoint || !Number.isFinite(volume.total) || volume.total <= 0
                || !Number.isFinite(volume.available) || volume.available < 0) continue;
        total += volume.total;
        var available = Math.min(volume.available, volume.total);
        free += available;
        used += Number.isFinite(volume.used) && volume.used >= 0
            ? Math.min(volume.used, volume.total) : volume.total - available;
        ++measured;
    }
    return measured ? {free:free, used:used, total:total, partial:measured < volumes.length} : null;
}
