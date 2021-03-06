args = commandArgs(trailingOnly=TRUE)

set.seed(1234)

if (length(args) < 3)
  stop("Missing required params: <data dir> <outdir> <info file dir> <Set: All,Training>")


suppressPackageStartupMessages( library(BarrettsProgressionRisk) )
suppressPackageStartupMessages( library(tidyverse) )
suppressPackageStartupMessages( library(glmnet) )
suppressPackageStartupMessages( library(gridExtra) )

suppressPackageStartupMessages(source('~/workspace/shallowwgs_pipeline/lib/data_func.R'))
suppressPackageStartupMessages(source('~/workspace/shallowwgs_pipeline/lib/load_patient_metadata.R'))
suppressPackageStartupMessages(source('~/workspace/shallowwgs_pipeline/lib/cv-pt-glm.R'))

get.tiles<-function(files, info, scale=T) {
  print(paste0("Scale:",scale))
  seg.tiles = do.call(bind_rows, lapply(files, function(x) readr::read_tsv(x, col_types=cols(.default=col_double(), X1=col_character()))))
  colnames(seg.tiles)[1] = 'sample'
  seg.tiles = seg.tiles %>% filter(sample %in% info$Samplename)
  samples = seg.tiles$sample
  
  seg.tiles = as.matrix(seg.tiles[,-1])
  rownames(seg.tiles) = samples
  dim(seg.tiles)
  
  # After mean centering set all NA values to 0
  prep.matrix(seg.tiles, scale=scale, MARGIN=2)
}

d.data = args[1]
# d.data = '~/Data/BarrettsProgressionRisk/Analysis/pcf_perPatient/50kb/'
v.data = args[2]
# v.data = '~/Data/BarrettsProgressionRisk/Analysis/validation/pcf_perPatient/50kb/'
outdir = args[3]
# outdir = '~/Data/BarrettsProgressionRisk/Analysis/dv_model_5e6_all_dvz/50kb/'
infodir = args[4]
# infodir = '~/Data/BarrettsProgressionRisk/QDNAseq'

select.alpha = 0.9

cache.dir = outdir
dir.create(cache.dir, recursive=T, showWarnings=F)

d.resids = do.call(bind_rows,purrr::map(list.files(d.data, 'residuals.tsv', recursive=T, full.names=T), function(f) read_tsv(f, col_types = c('ccddddl'))))
v.resids = do.call(bind_rows,purrr::map(list.files(v.data, 'residuals.tsv', recursive=T, full.names=T), function(f) read_tsv(f, col_types = c('ccddddl'))))

## Hospital.Research.ID info file
patient.file = list.files(infodir, pattern='All_patient_info.xlsx', recursive=T, full.names=T)
demo.file = list.files(infodir, pattern='Demographics_full.xlsx', recursive=T, full.names=T)
d.info = read.patient.info(patient.file, demo.file, set='All')$info %>% 
  dplyr::arrange(Status, Patient, Endoscopy.Year, Pathology) %>% dplyr::rename(Endoscopy = 'Endoscopy.Year') %>%
  mutate(Endoscopy = as.Date(paste0(Endoscopy,'-01-01')), Block = as.character(Block))

d.resids = d.resids %>% filter(varMAD_median <= 0.008)
d.info = d.info %>% filter(Samplename %in% d.resids$samplename)

v.patient.file = list.files(infodir, pattern='sWGS_validation_batches.xlsx', recursive=T, full.names=T)
v.info = readxl::read_xlsx(v.patient.file, 'Final Validation Samples') %>% 
  filter(Pathology != 'OAC') %>%
  dplyr::mutate_at(vars(`SLX-ID`, `Block ID`), list(as.character)) %>% dplyr::filter(!is.na(`SLX-ID`)) %>%
  mutate(Samplename = paste(`SLX-ID`, `Index Sequence`, sep='.')) %>%
  separate(`Block ID`, c('PID','Block'), sep='-|[:blank:]', remove=F) %>% dplyr::rename(PathID = `Block ID`) %>%
  dplyr::select(-matches('SLX|Index'), -`Path Notes`) %>%
  mutate(Pathology = recode(Pathology, 'GM'='NDBE'), Status = factor(Status, levels=c('NP','P'))) %>% 
  ungroup %>% group_by(`Hospital Research ID`) %>% mutate(Endoscopy = as.Date(Endoscopy)) %>% 
  dplyr::rename(Hospital.Research.ID = 'Hospital Research ID')

v.resids = v.resids %>% filter(varMAD_median <= 0.008)
v.info = v.info %>% filter(Samplename %in% v.resids$samplename)

info = bind_rows(d.info %>% dplyr::select(Status, Patient, matches('Hospital'),PID,Endoscopy,Pathology,Samplename,Block) %>% mutate(cohort='discovery'),
                 v.info %>% dplyr::select(Status, Patient, matches('Hospital'),PID,Endoscopy,Pathology,Samplename,Block) %>% mutate(cohort='validation')) %>% 
  mutate(Status = factor(Status, levels = c('NP','P')), Pathology = recode(Pathology, 'BE'='NDBE'))

d.cleaned = list.files(path=d.data, pattern='tiled_segvals', full.names=T, recursive=T)
v.cleaned = list.files(path=v.data, pattern='tiled_segvals', full.names=T, recursive=T)

cleaned = c(d.cleaned,v.cleaned)
cleaned = grep('OCCAMS',cleaned, value=T, invert = T)

arm.files = c(grep('arm', cleaned, value=T))
seg.files = c(grep('arm', cleaned, value=T, invert=T))

if (length(seg.files) != length(arm.files)) stop("Tiled files do not match between short segments and arms.")

segsList = get.tiles(seg.files, info, T)
armsList = get.tiles(arm.files, info, T)

segs = segsList$matrix
z.mean = segsList$z.mean
z.sd = segsList$z.sd

arms = armsList$matrix
z.arms.mean = armsList$z.mean
z.arms.sd = armsList$z.sd

# Complexity score
cx.score = BarrettsProgressionRisk::scoreCX(segs,1)
mn.cx = mean(cx.score)
sd.cx = sd(cx.score)

# Merge segments and arms, subtract arms
allDf = BarrettsProgressionRisk::subtractArms(segs, arms)
mn.cx = sqrt(mean(cx.score^2))

# Add complexity score
allDf = cbind(allDf, 'cx'=BarrettsProgressionRisk:::unit.var(cx.score, mn.cx, sd.cx))
dim(allDf)
## labels: binomial: prog 1, np 0
sampleStatus = info %>% ungroup %>% filter(Samplename %in% rownames(allDf)) %>% dplyr::select(Samplename,Status) %>% 
  mutate(Status = ifelse(Status == 'OAC', 'P', Status)) %>% mutate(Status = as.integer(Status)-1) 

# MAKE SURE the labels don't get mixed up
labels = sampleStatus %>% spread(Samplename, Status) %>% unlist
dysplasia.df = as.matrix(allDf[sampleStatus$Samplename,])
labels = labels[rownames(dysplasia.df)]

if (length(which(names(labels) == rownames(dysplasia.df))) != length(labels)) stop("Labels and x matrix mismatched!")

dim(dysplasia.df)

save(dysplasia.df, labels, mn.cx, sd.cx, z.mean, z.sd, z.arms.mean, z.arms.sd, file=paste(cache.dir, 'model_data.Rdata', sep='/'))

nl = 1000;folds = 10; splits = 5 

create.patient.sets2<-function(pts, n, splits, minR=0.2, uniquePtID = 'Patient') {
  # This function just makes sure the sets don't become too unbalanced with regards to the labels.
  pts = pts %>% mutate(label = as.integer(Status)-1)
  
  sample.ratio = pts %>% dplyr::select(Samplename, cohort) %>% group_by(cohort) %>% tally %>% mutate(n = n/sum(n))
  wt = pts %>% ungroup %>% dplyr::select(!!uniquePtID, cohort) %>% distinct() %>% mutate( wt = ifelse(cohort == 'discovery', 0.78, 0.22)) %>% dplyr::select(wt) %>% pull
  
  check.sets<-function(df, grpCol, min) {
    sets = table(cbind.data.frame('set'=df[[grpCol]], 'labels'=df$label))
    while ( (length(which(sets/rowSums(sets) < minR) ) >= 2 | length(which(sets/rowSums(sets) == 0)) > 0) ) {
      print(sets/rowSums(sets))
      #s = sample(rep(seq(5), length = length(unique(df[[uniquePtID]]))))
      s = sample( rep(seq(splits), length=length(unique(pts[[uniquePtID]]))), prob=wt )
      df2 = merge(df, cbind(unique(df[[uniquePtID]]), 'tmpgrp'=s), by=1)
      df[[grpCol]] = df2$tmpgrp
      sets = table(cbind.data.frame('set'=df[[grpCol]], 'labels'=df$label))
    }
    return(df[[grpCol]])
  }
  
  s = sample( rep(seq(splits), length=length(unique(pts[[uniquePtID]]))), prob=wt )
  patients = pts %>% left_join( bind_cols( !!quo_name(uniquePtID) := unique(pts[[uniquePtID]]), group=s ), by=uniquePtID) %>% dplyr::select(-Status,-cohort) %>% 
    dplyr::rename( fold.1 = 'group')
  patients$fold.1 = check.sets(patients, 'fold.1', minR)
  
  for (i in 2:n) {
    s = sample( rep(seq(splits), length=length(unique(pts[[uniquePtID]]))), prob=wt )
    patients = patients %>% left_join( bind_cols( !!quo_name(uniquePtID) := unique(pts[[uniquePtID]]), group=s ), by=uniquePtID) %>% 
      dplyr::rename( !!quo_name(paste0('fold.',i)) := 'group')
    
    patients[[paste0('fold.',i)]] = check.sets(patients, paste0('fold.',i))
  }
  return(patients)
}
sets = create.patient.sets2(info %>% dplyr::select(Patient,Samplename,Status,cohort), folds, splits, 0.2, 'Patient')  
#sets = create.patient.sets(info %>% ungroup %>% dplyr::select(Patient,Samplename,Status), folds, splits, 0.2)  
#sets = dplyr::select(info, Patient, Samplename, cohort) %>% left_join(sets, by = c("Patient", "Samplename"))

alpha.values = c(0,0.5,0.7,0.8,0.9,1)
#alpha.values = select.alpha
## ----- All ----- ##
coefs = list(); plots = list(); performance.at.1se = list(); models = list(); cvs = list()
file = paste(cache.dir, 'all.pt.alpha.Rdata', sep='/')
if (file.exists(file)) {
  message(paste("loading", file))
  load(file, verbose=T)
} else {
  for (a in alpha.values) {
    print(a)
    
    fit0 <- glmnet(dysplasia.df, labels[rownames(dysplasia.df)], alpha=a, nlambda=nl, family='binomial', standardize=F)    
    l = fit0$lambda
    #if (a > 0.5) l = more.l(l)
    
    cv.patient = crossvalidate.by.patient(x=dysplasia.df, y=labels[rownames(dysplasia.df)], lambda=l, pts=sets, sampleID=2, a=a, nfolds=folds, splits=splits, fit=fit0, select='deviance', opt=-1, standardize=F)
    
    lambda.opt = cv.patient$lambda.1se
    
    coef.opt = as.data.frame(non.zero.coef(fit0, lambda.opt))
    coefs[[as.character(a)]] = coef.stability(coef.opt, cv.patient$non.zero.cf)
    
    plots[[as.character(a)]] = arrangeGrob(cv.patient$plot+ggtitle('Classification'), cv.patient$deviance.plot+ggtitle('Binomial Deviance'), top=paste('alpha=',a,sep=''), ncol=2)
    
    performance.at.1se[[as.character(a)]] = subset(cv.patient$lambdas, `lambda-1se`)
    models[[as.character(a)]] = fit0
    cvs[[as.character(a)]] = cv.patient
  }
  save(plots, coefs, performance.at.1se, dysplasia.df, models, cvs, labels, file=file)
  p = do.call(grid.arrange, c(plots[ as.character(alpha.values) ], top='All samples, 10fold, 5 splits'))
  ggsave(paste(cache.dir, '/', 'all_samples_cv.png',sep=''), plot = p, scale = 2, width = 12, height = 10, units = "in", dpi = 300)
}
all.coefs = coefs
# ----------------- #



## --------- LOO --------- ##
message("LOO")

pg.samp = info %>% rowwise %>% dplyr::mutate(
  Probability = NA,
  RR = NA,
) %>% filter(Samplename %in% rownames(dysplasia.df))

file = paste(cache.dir, paste0('loo_',select.alpha,'.Rdata'), sep='/')
if (file.exists(file)) {
  message(paste("loading file", file))
  load(file, verbose=T)
} else {
  secf = all.coefs[[select.alpha]]
  a = select.alpha
  
  performance.at.1se = c(); coefs = list(); plots = list(); fits = list(); nzcoefs = list()
  # Remove each patient (LOO)
  for (pt in unique(pg.samp$Hospital.Research.ID)) {
    pt.path = paste0(cache.dir, '/plots/', pt)
    dir.create(pt.path, recursive = T, showWarnings = F)
    
  #for (pt in names(pg.samp)) {
    print(pt)
    samples = subset(pg.samp, Hospital.Research.ID != pt)$Samplename
    
    train.rows = which(rownames(dysplasia.df) %in% samples)
    training = dysplasia.df[train.rows,,drop=F]
    test = as.matrix(dysplasia.df[-train.rows,,drop=F])
    if (ncol(test) <= 0) next # shouldn't be any but...

    patient.samples = pg.samp %>% filter(Hospital.Research.ID == pt) %>% dplyr::select(Samplename)
    # Predict function giving me difficulty when I have only a single sample, this ensures the dimensions are the same
    sparsed_test_data <- Matrix(data=0, nrow=ifelse(nrow(patient.samples) > 1, nrow(test), 1),  ncol=ncol(training),
                                dimnames=list(rownames(test),colnames(training)), sparse=T)
    
    for(i in colnames(dysplasia.df)) sparsed_test_data[,i] = test[,i]
    
    # Fit generated on all samples, including HGD
    fitLOO <- glmnet(training, labels[train.rows], alpha=a, family='binomial', nlambda=nl, standardize=F) # all patients
    l = fitLOO$lambda
    
    cv = crossvalidate.by.patient(x=training, y=labels[train.rows], lambda=l, a=a, nfolds=folds, splits=splits,
                                  pts=subset(sets, Samplename %in% samples), sampleID=2, fit=fitLOO, standardize=F)
    
    plots[[pt]] = arrangeGrob(cv$plot+ggtitle('Classification'), cv$deviance.plot+ggtitle('Binomial Deviance'), top=pt, ncol=2)
    
    fits[[pt]] = cv  
    
    if ( length(cv$lambda.1se) > 0 ) {
      performance.at.1se = c(performance.at.1se, subset(cv$lambdas, lambda == cv$lambda.1se)$mean)
      
      nzcoefs[[pt]] = as.data.frame(non.zero.coef(fitLOO, cv$lambda.1se))
      
      coefs[[pt]] = coef(fitLOO, cv$lambda.1se)[rownames(secf),]

      logit <- function(p){log(p/(1-p))}
      inverse.logit <- function(or){1/(1 + exp(-or))}
      
      tmp.cvRR = tibble::enframe(BarrettsProgressionRisk:::non.zero.coef(fitLOO, cv$lambda.1se)[-1], name='label') %>% 
        dplyr::rename(coef = 'value') %>%
        mutate(cvRR = BarrettsProgressionRisk:::cvRR(test, as.matrix(BarrettsProgressionRisk:::non.zero.coef(fitLOO, cv$lambda.1se)[-1], ncol=1))) %>% 
        arrange(desc(cvRR))
      
      # mp = BarrettsProgressionRisk:::mountainPlots(tiles = test, coefs = as.matrix(coef(fitLOO, cv$lambda.1se)), cvRR = tmp.cvRR, build = 'hg19')
      # p = do.call(gridExtra::arrangeGrob, c(mp$plot.list, ncol=1))
      # for (pn in names(mp$plot.list)) { 
      #   ggsave(filename=paste0(pt.path,'/',pn,'.png'), plot=mp$plot.list[[pn]],width=12,height=4,units='in')
      # }

      pm = predict(fitLOO, newx=sparsed_test_data, s=cv$lambda.1se, type='response')
      colnames(pm) = 'Probability'
      
      rr = predict(fitLOO, newx=sparsed_test_data, s=cv$lambda.1se, type='link')
      colnames(rr) = 'RR'
      
      sy = as.matrix(sqrt(binomial.deviance(pm,labels[intersect(patient.samples$Samplename, names(labels))])))
      colnames(sy) = 'Prob.Dev.Resid'
      if (nrow(test) == 1) rownames(sy) = rownames(pm)
      
      patient = pg.samp %>% filter(Hospital.Research.ID == pt) %>% arrange(Samplename) 
      
      patient$Probability = pm[patient$Samplename,]
      patient$RR = rr[patient$Samplename,]
#      patient$Prob.Dev.Resid = sy[patient$Samplename,]
      
      pg.samp[which(pg.samp$Hospital.Research.ID == pt),] = patient

    } else {
      warning(paste("Hospital.Research.ID", pt, "did not have a 1se"))
    }
  }
  save(plots, performance.at.1se, coefs, nzcoefs, fits, pg.samp, file=file)
}


message("Finished")

