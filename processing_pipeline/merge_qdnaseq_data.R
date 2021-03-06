args = commandArgs(trailingOnly=TRUE)

if (length(args) <2)
  stop("Missing required arguments: <qdna data dir> <patient spreadsheet>")


library(tidyverse)

#library(ggrepel)
#library(gridExtra)
#library(BarrettsProgressionRisk)
source('~/workspace/shallowwgs_pipeline/lib/load_patient_metadata.R')

data = args[1]
val.file = args[2]
normals = F
if (length(args) == 3) normals = as.logical(args[3])

 data = '~/Data/BarrettsProgressionRisk/QDNAseq/qc_batches/'
 val.file = '~/Data/BarrettsProgressionRisk/QDNAseq/qc_batches/qc_batches.xlsx'
#val.file = '~/Data/BarrettsProgressionRisk/QDNAseq/training/All_patient_info.xlsx'

pastefun<-function(x) {
  if ( !grepl('SLX-', x) ) x = paste0('SLX-',x)
  return(x)
}

sheets = readxl::excel_sheets(val.file)
all = grep('All',sheets,value=T)

if (length(all) == 1) {
  all.info = read.patient.info(val.file, sheet=all)
  if (normals) { 
    all.info = all.info$normal
  } else {
    all.info = all.info$info
  }
  all.info = all.info %>% dplyr::rename(`SLX-ID` = 'SLX.ID')
} else {
  all.info = do.call(bind_rows, lapply(sheets, function(s) {
    print(s)
    readxl::read_xlsx(val.file, s) %>% dplyr::select(`Hospital Research ID`, matches('Status'), `Sample Type`, `SLX-ID`, `Index Sequence`, Batch) %>% 
      dplyr::filter(!is.na(`SLX-ID`)) %>%
      mutate_at(vars(`SLX-ID`), list(as.character))
  }))
  all.info = all.info %>% rowwise %>% mutate_at(vars(`SLX-ID`), list(pastefun) ) %>% ungroup
  all.info = all.info %>% 
    mutate(`Hospital Research ID` = str_replace_all( str_remove_all(`Hospital Research ID`, " "), '/', '_'), `Index Sequence` = str_replace_all(`Index Sequence`, 'tp', ''))  
}

print(unique(all.info$`SLX-ID`))

ld = list.dirs(data, full.names=T, recursive=F)
slx = gsub('SLX-','',paste(unique(all.info$`SLX-ID`),collapse='|'))

data.dirs = grep(slx,ld,value=T)

qd.bins = grep('kb',unique(basename(list.dirs(data.dirs, recursive = T))), value=T)

if (length(data.dirs) <= 0)
  stop(paste("No directories in", data))

fix.index <-function(x) { 
  x = str_replace_all(x, '_', '-') 
  str_replace_all(x, '.H.*.s-\\d', '')
}

for (bin in qd.bins) {
  print(data.dirs)

  #dirs = grep(bin,data.dirs,value=T)
  
  merged.raw = NULL; merged.fit = NULL
  for (dir in data.dirs) {
    dir = paste0(dir,'/',bin)
    print(dir)
  
    files = list.files(dir, 'txt',full.names=T,recursive=T)
    
    rawFile = grep('raw',files,value=T)
    fittedFile = grep('fitted',files,value=T)

    if (length(rawFile) < 1 | length(fittedFile) < 1) {
      message(paste("Missing raw or fitted file for ",dir))
      next
    } else if (length(rawFile) == 1) {
      raw.data = read_tsv(rawFile, col_types = cols('chrom'=col_character()))
      fitted.data = read_tsv(fittedFile, col_types = cols('chrom'=col_character()))
    } else {
      raw.data = NULL; fitted.data = NULL
      for (file in rawFile) {
        print(file)
        raw = read_tsv(file, col_types = cols('chrom'=col_character()))
        fit = read_tsv(grep(sub('\\.binSize.*','',basename(file)), fittedFile, value=T), col_types = cols('chrom'=col_character()))
        
        colnames(fit)[5] = sub('\\.binSize.*','',basename(file))
        colnames(raw)[5] = sub('\\.binSize.*','',basename(file))
        
        if (is.null(fitted.data)) {
          fitted.data = fit
          raw.data = raw
        } else {
          fitted.data = merge(fitted.data, fit, by=c('location','chrom','start','end'), all=T) 
          raw.data = merge(raw.data, raw, by=c('location','chrom','start','end'), all=T) 
        }
      }
    }
    
    if ( length(which(grepl('tp',colnames(raw.data)))) > 0) {
      colnames(raw.data) = gsub('tp','', colnames(raw.data))
      colnames(fitted.data) = gsub('tp','', colnames(fitted.data))
    }
    
    if (is.null(merged.fit)) {
      merged.fit = fitted.data
      merged.raw = raw.data
    } else {
      merged.fit = full_join(merged.fit, fitted.data, by=c('location','chrom','start','end'))
      merged.raw = full_join(merged.raw, raw.data, by=c('location','chrom','start','end'))
    }
    
    print(dim(merged.fit))
  }
  
  #merged.fit = merged.fit %>% rename_at(vars(matches('^SLX-')), fix.index)
  #merged.raw = merged.raw %>% rename_at(vars(matches('^SLX-')), fix.index)

  if (normals) {
    merged.fit = merged.fit %>% dplyr::select( location, chrom, start, end, all.info$Samplename )
    merged.raw = merged.raw %>% dplyr::select( location, chrom, start, end, all.info$Samplename )
  }
  
  
  outdir = paste0(data,'/merged/',bin)
  if (normals) outdir = paste0(data,'/normals/',bin)

  print(paste0("Writing merged raw and fit data to ", outdir, '/merged_raw_fit.Rdata'))

  if (!dir.exists(outdir)) dir.create(outdir, recursive=T, showWarnings=F)
    
  save(merged.fit, merged.raw, file=paste0(outdir, '/merged_raw_fit.Rdata'))
}

print("Finished.")
