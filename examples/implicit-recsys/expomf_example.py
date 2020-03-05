# 
# Copyright (c) 2020 Minato Sato
# All rights reserved.
#
# This source code is licensed under the license found in the
# LICENSE file in the root directory of this source tree.
#

import cymf

import argparse
parser = argparse.ArgumentParser(description='')
parser.add_argument('--num_epochs', type=int, default=5)
parser.add_argument('--num_components', type=int, default=20)
parser.add_argument('--weight_decay', type=float, default=0.1)
parser.add_argument('--num_threads', type=int, default=8)

args = parser.parse_args()

dataset = cymf.dataset.MovieLens("ml-100k")

evaluator = cymf.evaluator.AverageOverAllEvaluator(dataset.test, dataset.train, k=5)
model = cymf.ExpoMF(num_components=args.num_components, lam_y=args.weight_decay, weight_decay=args.weight_decay)
for i in range(args.num_epochs):
    model.fit(dataset.train, num_epochs=1, num_threads=args.num_threads, verbose=False)
    print(evaluator.evaluate(model.W, model.H))

