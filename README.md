# TRAIN — ERA5 patch for the new CDS

TRAIN cannot read the ERA5 netCDF files the Climate Data Store has served since
the 2024 migration. This patch fixes that, makes `model_type='era5'` work, and
lets the chain run headless. MATLAB code only — no data file is touched.


## Apply it

| | |
|---|---|
| `TRAIN_ERA5_patch_bash.ipynb` | every step as bash. Sets `APS_toolbox` for you — **easiest** |
| `TRAIN_ERA5_patch.ipynb` | the same steps in Python |
| `TRAIN_ERA5_newCDS.patch` | `cd /path/to/TRAIN && git apply patches/TRAIN_ERA5_newCDS.patch` |

Both notebooks find TRAIN, back up, apply, verify and can roll back. Re-running
does no harm. The `.patch` is a plain diff against upstream `6c93feb`.

If you use the `.patch`, edit one line afterwards (the notebooks do it for you):

```bash
export APS_toolbox="/path/to/TRAIN"    # <-- your own absolute path
```

## What it fixes

| file | fix |
|---|---|
| `aps_load_era.m` | reads the new CDS layout: `pressure_level`/`valid_time` names, `expver` skipped, lat/lon by name, levels sorted surface-first, level count no longer hard-coded to 37 |
| `aps_weather_model_SAR.m`, `_InSAR.m`, `_filenames.m` | `era5` datapath and file names, plus the hourly time list that `aps_era5_files.m` actually downloads |
| `get_DEM.m` | `grdinfo -C` instead of the `temp3` file (GMT 6); no `input()` prompt under `matlab -batch` |
| `get_gmt_version.m` | recognises the GMT 6 `usage:` string |

## Do not use `ncrename`

The usual workaround —

```bash
ncrename -d pressure_level,level -v pressure_level,level file.nc
```

— silently wipes the coordinate variables on netCDF-4. `z`/`t`/`r` survive, but
the levels come back all-NaN and you get an all-NaN delay map with no error.

The patch reads both spellings, so this is unnecessary. It also repairs files
already damaged: it rebuilds the levels from an intact sibling file, or from the
standard ECMWF set, then orients them against the geopotential. Section 9 of
either notebook tells you which of your files are affected.

## Running it

```matlab
setparm_aps('era_datapath', '/absolute/path/to/ERA_5')
setparm_aps('era_data_type', 'ECMWF')
setparm_aps('UTC_sat', '05:10')

aps_weather_model('era5', 0, 0)   % dry run: dates and expected files
aps_weather_model('era5', 1, 1)   % download (needs ~/.cdsapirc)
aps_weather_model('era5', 2, 4)   % compute, writes tca2.mat
```

Then in StaMPS: `ps_plot('a','a_era5')` — or `a_erai` for the `era` route.

### era or era5?

`era5` is hourly, so it samples closer to the acquisition. On the DES Rendinara
data (23 images) the two came out equivalent: correlated 0.983 with each other,
residual phase–topography correlation 0.343 (`era`) against 0.339 (`era5`). Look
at both fields before setting `tropo_method`.
