## load all of Ellie's data, merge, then break into per-patient raw/fitted files. Run segmentation and save results.

options(bitmapType = "cairo")


args = commandArgs(trailingOnly=TRUE)

if (length(args) < 3)
  stop("Missing required arguments: <qdna data dir> <patient spreadsheet> <output dir> <patient name OPT>")

suppressPackageStartupMessages( library(BarrettsProgressionRisk) )
source('~/workspace/shallowwgs_pipeline/lib/load_patient_metadata.R')

data = args[1]
patient.file = args[2]
outdir = args[3]
# data = '~/Data/Ellie/QDNAseq/training/'
# patient.file = paste(data, 'All_patient_info.xlsx', sep='/')
# outdir = '~/Data/Ellie/Analysis/IntPloidy'

patient.name = NULL
if (length(args) == 4)
  patient.name = args[4]

all.patient.info = read.patient.info(patient.file, set='All')$info
if (is.null(all.patient.info))
  stop(paste("Failed to read patient file", patient.file))

pts_slx = arrange(unique(all.patient.info[c('SLX.ID','Hospital.Research.ID')]), Hospital.Research.ID)

#datafile = paste(data,'excluded_qdnaseq_output.Rdata',sep='/')
datafile = paste(data,"merged_qdnaseq_output.Rdata", sep='/')
if (!file.exists(datafile)) {
  data.dirs = list.dirs(data, full.names=T, recursive=F)
  if (length(data.dirs) <= 0)
    stop(paste("No directories in", data))
  data.dirs = grep(paste(unique(pts_slx$SLX.ID), collapse='|'), data.dirs, value=T)

  # Load the data, binding each new data file into single data table
  fit.data = NULL
  raw.data = NULL
  samplenames=NULL
  for(dir in data.dirs) {
    print(paste("Reading directory", dir))
    files = list.files(dir,pattern="[fitted|corrected]ReadCounts.txt", full.names=T)
    slx = sub('SLX-','', basename(dir))
    
    # Files that do not contain individual indecies
    if (length(files) == 1 || !grepl('D\\d+_D\\d+', files)) {
      for (file in files) {
        print(paste("Reading file", file))
        spl = strsplit(basename(file),"\\.")
        
        fitted.file = file
        raw.file = list.files(dir, pattern='\\.(raw)?readCounts', full.names=T)
        if (length(raw.file) > 1)
          stop(paste("Error finding raw read counts in", dir))
        
        message( paste('FIT:', basename(fitted.file), '  RAW:', basename(raw.file)) )
        
        n = ncol(readr::read_tsv(fitted.file,col_names=T, n_max=1))
        
        fit = readr::read_tsv(fitted.file, col_types=paste(c('cc',rep('n',n-2)),collapse=''))
        
        f.cols = grep('D\\d', colnames(fit))
        colnames(fit)[f.cols] = paste(colnames(fit)[f.cols], slx, sep="_") 
        
        raw = readr::read_tsv(raw.file, col_types=paste(c('cc',rep('n',n-2)),collapse=''))
        
        r.cols = grep('D\\d', colnames(raw))
        colnames(raw)[r.cols] = paste(colnames(raw)[r.cols], slx, sep="_") 
        raw = raw[,colnames(fit)]	    
        
        if (is.null(fit.data)) {
          fit.data = fit
          raw.data = raw
        } else {
          fit.data = full_join(fit.data, fit, by=c('location','chrom','start','end'), all=T) 
          raw.data = full_join(raw.data, raw, by=c('location','chrom','start','end'), all=T) 
        }
      }
    } else { # individual index
      for(file in files){
        print(paste("Reading file", file))
        spl = strsplit(basename(file),"\\.")
        
        fitted.file = file
        raw.file = sub('fitted', 'raw', fitted.file)
        
        message( paste('FIT:', basename(fitted.file), '  RAW:', basename(raw.file)) )
        
        if (!file.exists(fitted.file) || !file.exists(raw.file)) 
          stop("Missing fitted/raw file ")
  
        n = ncol(readr::read_tsv(fitted.file,col_names=T, n_max=1))
        
        fit = readr::read_tsv(fitted.file, col_types=paste(c('cc',rep('n',n-2)),collapse=''))
        
        colnames(fit)[5] = paste(spl[[1]][2],slx,sep="_")
        
        raw = readr::read_tsv(raw.file, col_types=paste(c('cc',rep('n',n-2)),collapse=''))
        colnames(raw)[5] = paste(spl[[1]][2],slx,sep="_")
        
        if (is.null(fit.data)) {
          fit.data = fit
          raw.data = raw
        } else { # add to table
          fit.data = full_join(fit.data, fit, by=c('location','chrom','start','end'), all=T) 
          raw.data = full_join(raw.data, raw, by=c('location','chrom','start','end'), all=T) 
        }	  
      }
    }
    print(dim(fit.data))
  }
 
  save(fit.data, raw.data, file=datafile)
} else {
  load(datafile, verbose=T)
}

# plot.dir = paste(outdir, "coverage_binned_fitted", sep='/')
# if ( !dir.exists(plot.dir) ) 
#   dir.create(plot.dir, recursive = T)

multipcfdir = paste(outdir, "multipcf_perPatient", sep='/')
if ( !dir.exists(multipcfdir) ) 
  dir.create(multipcfdir, recursive = T)

if (!is.null(patient.name))
  pts_slx = subset(pts_slx, Hospital.Research.ID == patient.name)

tiled = NULL; tile.MSE = NULL
arms.tiled = NULL; arm.MSE = NULL

for (pt in unique(pts_slx$Hospital.Research.ID)) {
  print(pt)
  pd = paste(multipcfdir, pt,sep='/')
  
  if (!file.exists(paste0(pd,'/segment.Rdata'))) {
  
    dir.create(pd,showWarnings = F)
    
    info = all.patient.info %>% filter(Hospital.Research.ID == pt) %>% 
      dplyr::select('Patient','Hospital.Research.ID', 'Samplename','Endoscopy.Year','Block','Pathology','p53.Status') %>% 
      dplyr::rename('Sample' = 'Samplename', 'GEJ.Distance' = 'Block', 'p53 IHC' = 'p53.Status', 'Endoscopy' = 'Endoscopy.Year') %>% rowwise %>% 
      dplyr::mutate( Endoscopy = paste(as.character(Endoscopy), '01', '01', sep='-')   )
    info = BarrettsProgressionRisk::loadSampleInformation(info, path=c('BE','ID','LGD','HGD','IMC'))
  
    cols = which(colnames(fit.data) %in% subset(all.patient.info, Hospital.Research.ID == pt)$Samplename)
  
    segmented = BarrettsProgressionRisk::segmentRawData(info, raw.data[,c(1:4,cols)],fit.data[,c(1:4,cols)], verbose=T, cutoff=0.015*2)
    residuals = BarrettsProgressionRisk::sampleResiduals(segmented) %>% add_column('patient'=pt, .before=1)
  
    save(segmented, file=paste0(pd,'/segment.Rdata'))
    readr::write_tsv(residuals, path=paste0(pd,'/residuals.tsv'))
  
    message("Saving plots")
  
    plotdir = paste0(pd,'/segmented_plots')
    dir.create(plotdir, showWarnings=F )
    plots = BarrettsProgressionRisk::plotSegmentData(segmented, 'list')
    for (sample in names(plots)) 
      ggsave(filename=paste(plotdir, '/', sample, '_segmented.png',sep=''), plot=plots[[sample]] + labs(title=paste(pt, sample)), width=20, height=6, units='in', limitsize=F)
  
    ggsave(filename=paste0(plotdir, '/', pt, '_segmented.png'), plot=do.call(gridExtra::grid.arrange, c(plots, ncol=1, top=pt)), width=20, height=6*length(plots), units='in', limitsize=F) 
  
  
    plotdir = paste0(pd,'/cvg_binned_fitted')
    dir.create(plotdir, showWarnings=F )
    plots = BarrettsProgressionRisk::plotCorrectedCoverage(segmented, 'list') 
    for (sample in names(plots))    
      ggsave(filename=paste0(plotdir, '/', sample, '_cvg_binned.png'), plot=plots[[sample]] + labs(title=paste(pt, sample)), width=20, height=6, units='in', limitsize = F)
  
    ggsave(filename=paste0(plotdir, '/', pt, '_cvg_binned.png'), plot=do.call(gridExtra::grid.arrange, c(plots, ncol=1, top=pt)), width=20, height=6*length(plots), units='in', limitsize=F) 
  } else {
    load(file = paste0(pd,'/segment.Rdata'))
    
    tiles = BarrettsProgressionRisk::tileSegments(segmented, verbose=T)
    arms = BarrettsProgressionRisk::tileSegments(segmented, 'arms', verbose=T)
    
    write.table(arms$tiles, file=paste0(pd, '/arms_tiled_segvals.txt'), quote=F, sep='\t', row.names=T, col.names=NA)
    write.table(tiles$tiles, file=paste0(pd, '/5e06_tiled_segvals.txt'), quote=F, sep='\t', row.names=T, col.names=NA)
    
    write.table(arms$error, file=paste0(pd, '/arms_tiled_error.txt'), quote=F, sep='\t', row.names=T, col.names=NA)
    write.table(tiles$error, file=paste0(pd, '/5e06_tiled_error.txt'), quote=F, sep='\t', row.names=T, col.names=NA)
  }
  
}

message("Finished")
q(save="no")
